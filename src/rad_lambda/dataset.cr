require "./rle"

module RadLambda
  # A warped raster ready to encode as a RAD file. v1 matches
  # Tiles::TileDataset#save_to_file exactly; v2 (the default) prepends the
  # magic "RAD2" and swaps the payload to the skip-literal stream (see
  # RLE.compress_v2) — decoders branch on the magic, so both coexist.
  # Layout after the (v2-only) magic, all little-endian:
  #
  # | time            | Int64      | unix timestamp in milliseconds |
  # | geo_tran[0..5]  | Float64[6] | geo transform                  |
  # | max_x           | Int32      | width in pixels                |
  # | max_y           | Int32      | height in pixels               |
  # | no_data_value   | UInt8      | value representing no data     |
  # | data_size       | Int64      | uncompressed band size         |
  # | compressed_size | Int64      | RLE payload size               |
  # | data            | Byte[]     | RLE-compressed band            |
  class Dataset
    getter time : Time
    getter geo_tran : StaticArray(Float64, 6)
    getter max_x : Int32
    getter max_y : Int32
    getter data : Bytes
    getter no_data_value : UInt8

    def initialize(@time, @geo_tran, @max_x, @max_y, @data, @no_data_value)
    end

    MAGIC_V2 = "RAD2"

    def write(io : IO, version : Int32 = 2)
      io.write(MAGIC_V2.to_slice) if version == 2
      IO::ByteFormat::LittleEndian.encode(@time.to_unix_ms, io)
      @geo_tran.each { |val| IO::ByteFormat::LittleEndian.encode(val, io) }
      IO::ByteFormat::LittleEndian.encode(@max_x, io)
      IO::ByteFormat::LittleEndian.encode(@max_y, io)
      IO::ByteFormat::LittleEndian.encode(@no_data_value, io)
      IO::ByteFormat::LittleEndian.encode(@data.size.to_i64, io)
      compressed = version == 2 ? RLE.compress_v2(@data) : RLE.compress(@data)
      IO::ByteFormat::LittleEndian.encode(compressed.size.to_i64, io)
      io.write(compressed)
    end

    def to_bytes(version : Int32 = 2) : Bytes
      io = IO::Memory.new
      write(io, version)
      io.to_slice
    end
  end
end
