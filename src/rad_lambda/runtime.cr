require "http/client"
require "json"

module RadLambda
  # Minimal AWS Lambda custom runtime loop (the Runtime API is plain HTTP):
  # GET the next invocation, run the handler, POST the result or the error.
  module Runtime
    API_VERSION = "2018-06-01"

    def self.run(&handler : JSON::Any -> String)
      api = ENV["AWS_LAMBDA_RUNTIME_API"]
      client = HTTP::Client.new(URI.parse("http://#{api}"))

      loop do
        response = client.get("/#{API_VERSION}/runtime/invocation/next")
        request_id = response.headers["Lambda-Runtime-Aws-Request-Id"]

        begin
          result = handler.call(JSON.parse(response.body))
          client.post("/#{API_VERSION}/runtime/invocation/#{request_id}/response", body: result)
        rescue ex
          STDERR.puts "invocation #{request_id} failed: #{ex.message}"
          error = {errorMessage: ex.message || "unknown", errorType: ex.class.name}.to_json
          client.post("/#{API_VERSION}/runtime/invocation/#{request_id}/error", body: error)
        end
      end
    end
  end
end
