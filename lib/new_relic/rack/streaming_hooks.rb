# encoding: utf-8

require 'new_relic/agent/event_listener'
require 'new_relic/rack/agent_middleware'
require 'new_relic/agent/instrumentation/middleware_proxy'

module NewRelic::Rack
  class StreamingHooks < AgentMiddleware
    def self.needed?
      NewRelic::Agent.config[:instrument_rack_streaming]
    end

    def traced_call(env)
      segment = NewRelic::Agent::Tracer.start_segment(name: 'Middleware/Rack/StreamingHooks/response')

      app_segment = NewRelic::Agent::Tracer.start_segment(name: 'Middleware/Rack/StreamingHooks/call')
      status, headers, response = *@app.call(env)
      app_segment.finish

      if is_streaming?(headers)
        stream_segment = NewRelic::Agent::Tracer.start_segment(name: 'Middleware/Rack/StreamingHooks/stream')
        stream_wrapped_response = StreamingBodyProxy.new(response) {
          stream_segment.finish
          segment.finish
        }

        [status, headers, stream_wrapped_response]
      else
        segment.finish
        [status, headers, response]
      end
    end

    def is_streaming?(headers)
      return true if headers && headers['Transfer-Encoding'] == 'chunked'
    end

    class StreamingBodyProxy < ::Rack::BodyProxy
      # override #each and #close so that we can capture any errors in execution
      def each
        segment = NewRelic::Agent::Tracer.start_segment(name: 'Middleware/Rack/StreamingHooks/response_each')
        super
      rescue => e
        NewRelic::Agent.notice_error(e)
        raise
      ensure
        segment.finish
      end

      def close
        return if @closed

        segment = NewRelic::Agent::Tracer.start_segment(name: 'Middleware/Rack/StreamingHooks/response_close')
        @closed = true
        begin
          @body.close if @body.respond_to? :close
        rescue => e
          NewRelic::Agent.notice_error(e)
          raise
        ensure
          begin
            segment.finish
          ensure
            @block.call
          end
        end
      end
    end
  end
end
