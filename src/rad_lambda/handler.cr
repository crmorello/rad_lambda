require "json"
require "uri"
require "./warp"
require "./vsi_file"
require "./manifest"

module RadLambda
  # Pixel density of the prod CONUS precip output (6373x4161 over the CONUS
  # mercator extent). Every region is warped to this so all RADs share one
  # pixel density regardless of extent.
  CONUS_PIXEL_SIZE_M = 1222.8

  TIME_FORMAT = "%Y%m%d-%H%M%S"

  # Transport gzip at rest (Phase A): Lambda mode stores gzipped bodies with
  # Content-Encoding metadata; CLI mode writes plain files (a local file has
  # no header channel, and gzipped-on-disk would break the dev server flow).
  @@gzip_output = false

  def self.gzip_output=(value : Bool)
    @@gzip_output = value
  end

  def self.gzip_output? : Bool
    @@gzip_output
  end

  def self.resolution : Float64
    ENV["RAD_RESOLUTION"]?.try(&.to_f64) || CONUS_PIXEL_SIZE_M
  end

  # e.g. "/vsis3/my-bucket/rads/conus" or a local directory
  def self.output_dir : String
    ENV["RAD_OUTPUT"]? || raise "RAD_OUTPUT env var not set"
  end

  # The pipeline serves 10-minute slices (spec §12, amended 2026-07-14 —
  # stamps are ON the nominal grid now); MRMS still publishes SeamlessHSR
  # every 2 minutes, so off-grid stamps are skipped, not processed.
  SLICE_MINUTES = 10

  def self.on_slice_grid?(time : Time) : Bool
    time.minute % SLICE_MINUTES == 0 && time.second == 0
  end

  # First key path segment -> client region id prefix. CONUS is the primary
  # product and stays unprefixed ("20260714-174000.rad"); everything else is
  # lowercased ("ALASKA/..." -> "alaska_20260714-174000.rad").
  def self.region_prefix(key : String) : String
    region = key.split('/').first.downcase
    region == "conus" ? "" : "#{region}_"
  end

  # Serving path of the output dir for manifest URLs: explicit RAD_URL_PREFIX,
  # else derived from RAD_OUTPUT ("/vsis3/bucket/rads" -> "/rads"; local -> "").
  def self.url_prefix : String
    if explicit = ENV["RAD_URL_PREFIX"]?
      return explicit.rstrip('/')
    end
    out = output_dir.rstrip('/')
    if out.starts_with?("/vsis3/")
      parts = out.lchop("/vsis3/").split('/', 2)
      parts.size == 2 ? "/#{parts[1]}" : ""
    else
      ""
    end
  end

  # MRMS filenames embed the data time: ..._YYYYMMDD-HHMMSS.grib2(.gz)
  def self.time_from_filename(filename : String) : Time
    if match = filename.match(/(\d{8})-(\d{6})/)
      Time.parse_utc("#{match[1]} #{match[2]}", "%Y%m%d %H%M%S")
    else
      raise "no timestamp in filename: #{filename}"
    end
  end

  # One raster in, one RAD out. Returns the written path. `id_prefix` is the
  # region prefix baked into the frame id (see region_prefix).
  def self.process_file(input : String, out_dir : String,
                        resolution : Float64 = self.resolution,
                        id_prefix : String = "") : String
    time = time_from_filename(File.basename(input))
    dataset = Warp.run(input, time, resolution)
    out_path = "#{out_dir.rstrip('/')}/#{id_prefix}#{time.to_s(TIME_FORMAT)}.rad"
    bytes = dataset.to_bytes
    bytes = VsiFile.gzip(bytes) if gzip_output?
    VsiFile.write(out_path, bytes)
    out_path
  end

  # Normalize any trigger shape to raw S3 records. The production chain is
  # NOAA SNS -> our SQS -> event-source mapping, which nests THREE layers
  # (SQS record body = SNS envelope JSON, whose Message = the S3 event);
  # direct SNS->Lambda and raw S3 events also work, so local testing and a
  # topology change don't touch the handler.
  def self.s3_records(event : JSON::Any) : Array(JSON::Any)
    result = [] of JSON::Any
    records = event["Records"]?.try(&.as_a?)
    return result unless records
    records.each do |record|
      if body = record["body"]?                       # SQS envelope
        inner = JSON.parse(body.as_s)
        if message = inner["Message"]?                # SNS envelope inside
          result.concat(s3_records(JSON.parse(message.as_s)))
        else
          result.concat(s3_records(inner))
        end
      elsif sns = record["Sns"]?                      # direct SNS -> Lambda
        result.concat(s3_records(JSON.parse(sns["Message"].as_s)))
      elsif record["s3"]?
        result << record
      end
    end
    result
  end

  # Trigger event -> RAD per on-grid record + manifest rebuild.
  def self.handle_event(event : JSON::Any) : String
    outputs = [] of String
    skipped = 0
    s3_records(event).each do |record|
      bucket = record["s3"]["bucket"]["name"].as_s
      key = URI.decode_www_form(record["s3"]["object"]["key"].as_s)
      unless on_slice_grid?(time_from_filename(File.basename(key)))
        skipped += 1
        next
      end
      outputs << process_file("/vsis3/#{bucket}/#{key}", output_dir,
                              id_prefix: region_prefix(key))
    end
    Manifest.rebuild(output_dir, url_prefix) unless outputs.empty?
    {processed: outputs, skipped: skipped}.to_json
  end
end
