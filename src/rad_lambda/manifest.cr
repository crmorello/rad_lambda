require "json"
require "./vsi_file"

module RadLambda
  # Rebuilds manifest.json from a LISTING of the output dir — never
  # read-modify-write: concurrent region invocations would permanently lose
  # each other's appends, while list-based rebuild is f(bucket state), so
  # last-writer-wins converges. Shape mirrors the Go dev server's manifest.
  module Manifest
    # "20260714-174000" or "alaska_20260714-174000" (fixed-width stamps sort
    # lexicographically by time; the pattern doubles as junk filtering).
    ID_PATTERN   = /^(?:[a-z0-9]+_)?\d{8}-\d{6}$/
    STAMP_FORMAT = "%Y%m%d-%H%M%S"

    # Timestamp portion of an id (region prefix stripped).
    def self.stamp_of(id : String) : String
      idx = id.rindex('_')
      idx ? id[(idx + 1)..] : id
    end

    # Manifest JSON for a set of frame ids. `url_prefix` is the serving path
    # of the output dir ("" or "/rads" — no trailing slash).
    def self.build(ids : Array(String), url_prefix : String) : String
      sorted = ids.sort do |a, b|
        cmp = stamp_of(a) <=> stamp_of(b)
        cmp == 0 ? (a <=> b) : cmp
      end
      frames = sorted.map do |id|
        time = Time.parse_utc(stamp_of(id), STAMP_FORMAT).to_rfc3339
        {id: id, time: time, url: "#{url_prefix}/#{id}.rad", bytes: 0_i64}
      end
      {
        product:    "reflectivity",
        updated_at: frames.last?.try(&.[:time]) || "",
        frames:     frames,
      }.to_json
    end

    # List the output dir, rebuild, write manifest.json alongside the RADs.
    def self.rebuild(out_dir : String, url_prefix : String)
      dir = out_dir.rstrip('/')
      ids = VsiFile.read_dir(dir)
        .select(&.ends_with?(".rad"))
        .map(&.rchop(".rad"))
        .select(&.matches?(ID_PATTERN))
      json = build(ids, url_prefix).to_slice
      json = VsiFile.gzip(json) if RadLambda.gzip_output?
      VsiFile.write("#{dir}/manifest.json", json)
    end
  end
end
