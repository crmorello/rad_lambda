# Entry point. In a Lambda container (AWS_LAMBDA_RUNTIME_API set) it runs the
# runtime loop handling S3 notifications; locally it's a CLI:
#
#   rad_lambda <grib(.gz) | dir> [out_dir]     # out_dir defaults to <dir>/rads
require "./rad_lambda/handler"
require "./rad_lambda/runtime"

module RadLambda
  VERSION = "0.1.0"
end

RadLambda::Warp.setup

if ENV["AWS_LAMBDA_RUNTIME_API"]?
  # Store gzipped bodies with Content-Encoding metadata (RAD_GZIP=0 opts out).
  if ENV["RAD_GZIP"]? != "0"
    RadLambda.gzip_output = true
    RadLambda::VsiFile.mark_prefix_gzip(RadLambda.output_dir)
  end
  RadLambda::Runtime.run { |event| RadLambda.handle_event(event) }
elsif input = ARGV[0]?
  if File.directory?(input)
    out_dir = ARGV[1]? || File.join(input, "rads")
    files = Dir.glob(File.join(input, "*.{grib2,grb2}")) + Dir.glob(File.join(input, "*.grib2.gz"))
    files.sort.each do |file|
      puts RadLambda.process_file(file, out_dir)
    end
    puts "Wrote #{files.size} RAD file(s) to #{out_dir}"
  else
    out_dir = ARGV[1]? || File.dirname(input)
    puts RadLambda.process_file(input, out_dir)
  end
else
  puts "Usage: rad_lambda <grib(.gz) | dir> [out_dir]"
  exit 1
end
