require "spec"
require "file_utils"
require "../src/rad_lambda/dataset"

describe RadLambda::RLE do
  it "round-trips" do
    data = Bytes.new(100_000) { |i| i < 70_000 ? 0_u8 : (i % 7).to_u8 }
    compressed = RadLambda::RLE.compress(data)
    RadLambda::RLE.decompress(compressed, data.size.to_i64).should eq(data)
  end

  it "caps runs at UInt16::MAX" do
    data = Bytes.new(70_000, 42_u8)
    compressed = RadLambda::RLE.compress(data)
    # 70_000 = 65_535 + 4_465 -> two (value, count) triplets
    compressed.size.should eq(6)
    RadLambda::RLE.decompress(compressed, data.size.to_i64).should eq(data)
  end
end

describe RadLambda::Dataset do
  it "writes the v1 RAD header layout (no magic)" do
    geo = StaticArray(Float64, 6).new { |i| i.to_f64 }
    data = Bytes.new(12, 5_u8)
    time = Time.utc(2026, 7, 12, 1, 30)
    bytes = RadLambda::Dataset.new(time, geo, 4, 3, data, 0_u8).to_bytes(version: 1)

    io = IO::Memory.new(bytes)
    io.read_bytes(Int64, IO::ByteFormat::LittleEndian).should eq(time.to_unix_ms)
    6.times { |i| io.read_bytes(Float64, IO::ByteFormat::LittleEndian).should eq(i.to_f64) }
    io.read_bytes(Int32, IO::ByteFormat::LittleEndian).should eq(4)
    io.read_bytes(Int32, IO::ByteFormat::LittleEndian).should eq(3)
    io.read_bytes(UInt8, IO::ByteFormat::LittleEndian).should eq(0_u8)
    io.read_bytes(Int64, IO::ByteFormat::LittleEndian).should eq(12)
    compressed_size = io.read_bytes(Int64, IO::ByteFormat::LittleEndian)
    compressed_size.should eq(3) # one RLE triplet: value + uint16 count
  end
end

require "../src/rad_lambda/manifest"
require "../src/rad_lambda/handler"

describe RadLambda::Manifest do
  it "builds a manifest sorted by stamp with region-aware urls" do
    ids = ["alaska_20260714-174000", "20260714-174000", "20260714-173000"]
    json = JSON.parse(RadLambda::Manifest.build(ids, "/rads"))
    frames = json["frames"].as_a
    frames.map(&.["id"].as_s).should eq(["20260714-173000", "20260714-174000", "alaska_20260714-174000"])
    frames[0]["url"].as_s.should eq("/rads/20260714-173000.rad")
    frames[0]["time"].as_s.should eq("2026-07-14T17:30:00Z")
    json["updated_at"].as_s.should eq("2026-07-14T17:40:00Z")
    json["product"].as_s.should eq("reflectivity")
  end
end

describe "handler helpers" do
  it "derives region prefixes from keys" do
    RadLambda.region_prefix("CONUS/SeamlessHSR_00.00/20260714/x.grib2.gz").should eq("")
    RadLambda.region_prefix("ALASKA/SeamlessHSR_00.00/20260714/x.grib2.gz").should eq("alaska_")
    RadLambda.region_prefix("HAWAII/x").should eq("hawaii_")
  end

  it "gates to the 10-minute grid" do
    RadLambda.on_slice_grid?(Time.utc(2026, 7, 14, 17, 40, 0)).should be_true
    RadLambda.on_slice_grid?(Time.utc(2026, 7, 14, 17, 42, 0)).should be_false
    RadLambda.on_slice_grid?(Time.utc(2026, 7, 14, 17, 40, 30)).should be_false
  end

  it "unwraps SQS-wrapped SNS-wrapped S3 events" do
    s3_event = {Records: [{s3: {bucket: {name: "noaa-mrms-pds"},
                                object: {key: "CONUS/SeamlessHSR_00.00/20260714/MRMS_SeamlessHSR_00.00_20260714-174000.grib2.gz"}}}]}.to_json
    sns_envelope = {Type: "Notification", Message: s3_event}.to_json
    sqs_event = JSON.parse({Records: [{messageId: "m1", body: sns_envelope}]}.to_json)

    records = RadLambda.s3_records(sqs_event)
    records.size.should eq(1)
    records[0]["s3"]["object"]["key"].as_s.should contain("SeamlessHSR")
  end

  it "unwraps direct SNS and passes raw S3 through" do
    s3_event = {Records: [{s3: {bucket: {name: "b"}, object: {key: "CONUS/k"}}}]}
    sns_event = JSON.parse({Records: [{Sns: {Message: s3_event.to_json}}]}.to_json)
    RadLambda.s3_records(sns_event).size.should eq(1)
    RadLambda.s3_records(JSON.parse(s3_event.to_json)).size.should eq(1)
  end
end

describe "Manifest.rebuild" do
  it "lists a directory, filters junk, and writes manifest.json" do
    dir = File.tempname("radout")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "20260714-173000.rad"), "x")
      File.write(File.join(dir, "alaska_20260714-174000.rad"), "x")
      File.write(File.join(dir, "junk.txt"), "x")
      File.write(File.join(dir, "not-a-stamp.rad"), "x")

      RadLambda::Manifest.rebuild(dir, "/rads")

      json = JSON.parse(File.read(File.join(dir, "manifest.json")))
      ids = json["frames"].as_a.map(&.["id"].as_s)
      ids.should eq(["20260714-173000", "alaska_20260714-174000"])
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "RLE v2 (skip-literal)" do
  it "round-trips" do
    data = Bytes.new(100_000) { |i| i < 70_000 ? 0_u8 : (i % 7).to_u8 }
    v2 = RadLambda::RLE.compress_v2(data)
    RadLambda::RLE.decompress_v2(v2, data.size.to_i64).should eq(data)
  end

  it "matches the cross-language golden bytes" do
    # band: 5 zeros, literals 7,8,9, 6 zeros, literal 1
    # -> [skip=5][lit=3][7,8,9][skip=6][lit=1][1]
    band = Bytes[0, 0, 0, 0, 0, 7, 8, 9, 0, 0, 0, 0, 0, 0, 1]
    v2 = RadLambda::RLE.compress_v2(band)
    v2.should eq(Bytes[5, 3, 7, 8, 9, 6, 1, 1])
    RadLambda::RLE.decompress_v2(v2, band.size.to_i64).should eq(band)
  end

  it "merges short zero gaps into literals" do
    # gap of 3 (< GAP_MERGE) stays literal; gap of 4 starts a new token
    band = Bytes[7, 0, 0, 0, 8, 0, 0, 0, 0, 9]
    v2 = RadLambda::RLE.compress_v2(band)
    v2.should eq(Bytes[0, 5, 7, 0, 0, 0, 8, 4, 1, 9])
  end

  it "writes a v2 RAD with magic + header" do
    geo = StaticArray(Float64, 6).new { |i| i.to_f64 }
    band = Bytes[0, 0, 0, 0, 0, 7, 8, 9, 0, 0, 0, 0]
    bytes = RadLambda::Dataset.new(Time.utc(2026, 7, 14), geo, 4, 3, band, 0_u8).to_bytes
    String.new(bytes[0, 4]).should eq("RAD2")
    io = IO::Memory.new(bytes[4..])
    io.read_bytes(Int64, IO::ByteFormat::LittleEndian).should eq(Time.utc(2026, 7, 14).to_unix_ms)
  end
end
