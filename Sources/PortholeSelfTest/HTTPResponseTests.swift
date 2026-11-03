import Foundation
import PortholeCore

func httpResponseTests() {
    let plain = HTTPResponse("200 OK", "text/plain; charset=utf-8", "héllo")
    expect("http head: exact header order, Content-Length counts UTF-8 bytes", plain.head,
           "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 6\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
    expect("http head: body follows the head", plain.serialized, Data(plain.head.utf8) + Data("héllo".utf8))

    let allow = HTTPResponse("405 Method Not Allowed", "text/plain", "method not allowed", headers: [("Allow", "GET, HEAD")])
    expect("http head: extra headers go after Content-Length, before Cache-Control", allow.head,
           "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: 18\r\nAllow: GET, HEAD\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")

    var head = HTTPResponse("200 OK", "text/javascript", Data(count: 1234))
    head.sendsBody = false
    check("http head: HEAD keeps the real Content-Length but sends no body",
          head.head.contains("Content-Length: 1234\r\n") && head.serialized == Data(head.head.utf8))
}
