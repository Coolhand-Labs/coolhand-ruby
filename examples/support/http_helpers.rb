# frozen_string_literal: true

# Helpers shared by the examples that run local fake servers. Not a runnable example: bin/live-examples
# only picks up examples/*.rb.

# Records one pass/fail line; the including script collects failures in @failures.
def check(description, passed)
  puts "  #{passed ? 'PASS' : 'FAIL'}  #{description}"
  @failures << description unless passed
end

# Reads one HTTP request (head plus Content-Length body) off an accepted socket and returns the body.
def read_http_request(socket)
  head = +""
  head << socket.readpartial(65_536) until head.include?("\r\n\r\n")
  length = head[/content-length:\s*(\d+)/i, 1].to_i
  body = head.split("\r\n\r\n", 2)[1].to_s
  body << socket.readpartial(length - body.bytesize) while body.bytesize < length
  body
end
