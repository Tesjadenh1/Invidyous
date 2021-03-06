module HTTP::Handler
  @@exclude_routes_tree = Radix::Tree(String).new

  macro exclude(paths, method = "GET")
      class_name = {{@type.name}}
      method_downcase = {{method.downcase}}
      class_name_method = "#{class_name}/#{method_downcase}"
      ({{paths}}).each do |path|
        @@exclude_routes_tree.add class_name_method + path, '/' + method_downcase + path
      end
    end

  def exclude_match?(env : HTTP::Server::Context)
    @@exclude_routes_tree.find(radix_path(env.request.method, env.request.path)).found?
  end

  private def radix_path(method : String, path : String)
    "#{self.class}/#{method.downcase}#{path}"
  end
end

class Kemal::RouteHandler
  exclude ["/api/v1/*"]

  # Processes the route if it's a match. Otherwise renders 404.
  private def process_request(context)
    raise Kemal::Exceptions::RouteNotFound.new(context) unless context.route_found?
    content = context.route.handler.call(context)

    if !Kemal.config.error_handlers.empty? && Kemal.config.error_handlers.has_key?(context.response.status_code) && exclude_match?(context)
      raise Kemal::Exceptions::CustomException.new(context)
    end

    context.response.print(content)
    context
  end
end

class Kemal::ExceptionHandler
  exclude ["/api/v1/*"]

  private def call_exception_with_status_code(context : HTTP::Server::Context, exception : Exception, status_code : Int32)
    return if context.response.closed?
    return if exclude_match? context

    if !Kemal.config.error_handlers.empty? && Kemal.config.error_handlers.has_key?(status_code)
      context.response.content_type = "text/html" unless context.response.headers.has_key?("Content-Type")
      context.response.status_code = status_code
      context.response.print Kemal.config.error_handlers[status_code].call(context, exception)
      context
    end
  end
end

class FilteredCompressHandler < Kemal::Handler
  exclude ["/videoplayback", "/videoplayback/*", "/vi/*", "/ggpht/*"]

  def call(env)
    return call_next env if exclude_match? env

    {% if flag?(:without_zlib) %}
        call_next env
      {% else %}
        request_headers = env.request.headers

        if request_headers.includes_word?("Accept-Encoding", "gzip")
          env.response.headers["Content-Encoding"] = "gzip"
          env.response.output = Gzip::Writer.new(env.response.output, sync_close: true)
        elsif request_headers.includes_word?("Accept-Encoding", "deflate")
          env.response.headers["Content-Encoding"] = "deflate"
          env.response.output = Flate::Writer.new(env.response.output, sync_close: true)
        end

        call_next env
      {% end %}
  end
end

class APIHandler < Kemal::Handler
  only ["/api/v1/*"]

  def call(env)
    return call_next env unless only_match? env

    env.response.headers["Access-Control-Allow-Origin"] = "*"

    # Here we swap out the socket IO so we can modify the response as needed
    output = env.response.output
    env.response.output = IO::Memory.new

    begin
      call_next env

      env.response.output.rewind
      response = env.response.output.gets_to_end

      if env.response.headers["Content-Type"]?.try &.== "application/json"
        response = JSON.parse(response)

        if env.params.query["fields"]?
          fields_text = env.params.query["fields"]
          begin
            JSONFilter.filter(response, fields_text)
          rescue ex
            env.response.status_code = 400
            response = {"error" => ex.message}
          end
        end

        if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
          response = response.to_pretty_json
        else
          response = response.to_json
        end
      end
    rescue
    ensure
      env.response.output = output
      env.response.puts response

      env.response.flush
    end
  end
end

class DenyFrame < Kemal::Handler
  exclude ["/embed/*"]

  def call(env)
    return call_next env if exclude_match? env

    env.response.headers["X-Frame-Options"] = "sameorigin"
    call_next env
  end
end

# Temp fix for https://github.com/crystal-lang/crystal/issues/7383
class HTTP::Client
  private def handle_response(response)
    # close unless response.keep_alive?
    response
  end
end
