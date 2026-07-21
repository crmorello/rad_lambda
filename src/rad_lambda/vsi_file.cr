require "lib_gdal"
require "compress/gzip"

module RadLambda
  # Writes through GDAL's virtual filesystem so the same call handles local
  # paths and /vsis3/bucket/key (credentials come from the standard AWS_* env
  # vars, which Lambda provides).
  module VsiFile
    class WriteError < Exception
    end

    def self.write(path : String, bytes : Bytes)
      if path.starts_with?("/vsi")
        file = LibGDAL.vsif_open(path.to_unsafe, "wb".to_unsafe)
        raise WriteError.new("VSIFOpenL failed for #{path}") if file.null?
        begin
          written = LibGDAL.vsif_write(bytes.to_unsafe.as(Void*), 1, bytes.size, file)
          raise WriteError.new("VSIFWriteL wrote #{written}/#{bytes.size} bytes to #{path}") unless written == bytes.size
        ensure
          LibGDAL.vsif_close(file)
        end
      else
        Dir.mkdir_p(File.dirname(path))
        File.write(path, bytes)
      end
    end

    # Gzip bytes in memory (transport compression at rest: S3 objects are
    # stored gzipped with Content-Encoding metadata, so every HTTP client
    # inflates transparently — CloudFront won't compress octet-stream itself).
    def self.gzip(bytes : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io) { |gz| gz.write(bytes) }
      io.to_slice
    end

    # Registers Content-Encoding on all writes under `prefix` (S3 PUT headers
    # ride GDAL_HTTP_HEADERS; per-path so reads from other buckets are
    # untouched). Everything written under the prefix MUST then be gzipped.
    def self.mark_prefix_gzip(prefix : String)
      LibGDAL.vsi_set_path_specific_option(prefix.to_unsafe, "GDAL_HTTP_HEADERS".to_unsafe,
                                           "Content-Encoding: gzip".to_unsafe)
    end

    # Lists a directory's entry names (no paths). VSI-backed for /vsi*
    # (VSIReadDir handles /vsis3 listing with the same credentials as reads).
    def self.read_dir(path : String) : Array(String)
      if path.starts_with?("/vsi")
        list = LibGDAL.vsi_read_dir(path.to_unsafe)
        return [] of String if list.null?
        names = [] of String
        i = 0
        until (entry = list[i]).null?
          names << String.new(entry)
          i += 1
        end
        LibGDAL.csl_destroy(list)
        names
      elsif Dir.exists?(path)
        Dir.children(path)
      else
        [] of String
      end
    end
  end
end
