require "lib_gdal"
require "./dataset"

module RadLambda
  # In-process GDALWarp: raster in (local file or any GDAL /vsi path),
  # RAD-ready Dataset out. No temp files, no subprocess.
  module Warp
    class WarpError < Exception
    end

    def self.setup
      LibGDAL.all_register
    end

    # Opens a raster, transparently unwrapping gzip via GDAL's virtual
    # filesystem. Works for local paths and /vsis3/bucket/key alike.
    def self.open_dataset(path : String) : LibGDAL::GDALDatasetH
      gdal_path = path.ends_with?(".gz") && !path.starts_with?("/vsigzip/") ? "/vsigzip/#{path}" : path
      dataset = LibGDAL.open(gdal_path.to_unsafe.as(Pointer(Char)), LibGDAL::Access::ReadOnly)
      raise WarpError.new("GDALOpen failed for #{gdal_path}") if dataset.null?
      dataset
    end

    # Warps `src` to EPSG:3857 at a fixed `resolution` (mercator meters/pixel)
    # into an in-memory dataset. Caller must LibGDAL.close the result.
    def self.warp_to_web_mercator(src : LibGDAL::GDALDatasetH, resolution : Float64, resampler : String = "med") : LibGDAL::GDALDatasetH
      args = ["-of", "MEM", "-t_srs", "EPSG:3857", "-r", resampler, "-tr", resolution.to_s, resolution.to_s]
      argv = args.map(&.to_unsafe)
      argv << Pointer(UInt8).null

      options = LibGDAL.warp_app_options_new(argv.to_unsafe, Pointer(Void).null)
      raise WarpError.new("GDALWarpAppOptionsNew rejected #{args}") if options.null?

      usage_error = 0
      srcs = Slice(LibGDAL::GDALDatasetH).new(1, src)
      warped = LibGDAL.warp("".to_unsafe, LibGDAL::GDALDatasetH.null, 1, srcs.to_unsafe, options, pointerof(usage_error))
      LibGDAL.warp_app_options_free(options)
      raise WarpError.new("GDALWarp failed (usage_error=#{usage_error})") if warped.null?
      warped
    end

    # Reads band 1 of an open dataset into a Dataset.
    def self.to_dataset(dataset : LibGDAL::GDALDatasetH, time : Time) : Dataset
      max_x = LibGDAL.get_raster_x_size(dataset)
      max_y = LibGDAL.get_raster_y_size(dataset)

      geo = StaticArray(Float64, 6).new(0.0)
      LibGDAL.get_geo_transform(dataset, geo.to_unsafe)

      band = LibGDAL.get_raster_band(dataset, 1)
      has_no_data = 0
      no_data = LibGDAL.get_no_data_value(band, pointerof(has_no_data)).to_u8!

      buffer = Bytes.new(max_x.to_i64 * max_y)
      result = LibGDAL.raster_io(band, LibGDAL::RWFlag::Read, 0, 0, max_x, max_y, buffer, max_x, max_y, LibGDAL::DataType::GDT_Byte, 0, 0)
      raise WarpError.new("GDALRasterIO failed (#{result})") unless result == 0

      Dataset.new(time, geo, max_x, max_y, buffer, no_data)
    end

    # grib(.gz) in -> warped, RAD-ready Dataset out.
    def self.run(src_path : String, time : Time, resolution : Float64, resampler : String = "med") : Dataset
      src = open_dataset(src_path)
      begin
        warped = warp_to_web_mercator(src, resolution, resampler)
        begin
          to_dataset(warped, time)
        ensure
          LibGDAL.close(warped)
        end
      ensure
        LibGDAL.close(src)
      end
    end
  end
end
