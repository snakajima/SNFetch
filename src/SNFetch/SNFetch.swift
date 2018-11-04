//
//  SNFetch.swift
//  SNFetch
//
//  Created by satoshi on 11/23/15.
//  Copyright © 2015 Satoshi Nakajima. All rights reserved.
//

import Foundation

class SNFetchError: NSObject, Error {
    let res:HTTPURLResponse
    init(res:HTTPURLResponse) {
        self.res = res
    }
    
    var localizedDescription:String {
        // LAZY
        return self.description
    }
    
    override var description:String {
        let message:String
        switch(res.statusCode) {
        case 400:
            message = "Bad Request"
        case 401:
            message = "Unauthorized"
        case 402:
            message = "Payment Required"
        case 403:
            message = "Forbidden"
        case 404:
            message = "Not Found"
        case 405:
            message = "Method Not Allowed"
        case 406:
            message = "Proxy Authentication Required"
        case 407:
            message = "Request Timeout"
        case 408:
            message = "Request Timeout"
        case 409:
            message = "Conflict"
        case 410:
            message = "Gone"
        case 411:
            message = "Length Required"
        case 500:
            message = "Internal Server Error"
        case 501:
            message = "Not Implemented"
        case 502:
            message = "Bad Gateway"
        case 503:
            message = "Service Unavailable"
        case 504:
            message = "Gateway Timeout"
        default:
            message = "HTTP Error"
        }
        return "\(message) (\(res.statusCode))"
    }
}

class SNFetch:NSObject {
    static let boundary = "0xKhTmLbOuNdArY---This_Is_ThE_BoUnDaRyy---pqo"
    private static let regex = try! NSRegularExpression(pattern: "^https?:", options: NSRegularExpression.Options())
    static func encode(_ string: String) -> String {
        // URL encoding: RFC 3986 http://www.ietf.org/rfc/rfc3986.txt
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~")
        
        // The following force-unwrap fails if the string contains invalid UTF-16 surrogate pairs,
        // but the case can be ignored unless a string is constructed from UTF-16 byte data.
        // http://stackoverflow.com/a/33558934/4522678
        return string.addingPercentEncoding(withAllowedCharacters: allowedCharacters)!
    }
    let root:URL
    var session:URLSession!
    var extraHeaders = [String:String]()
    init(_ root:URL) {
        self.root = root
        let config = URLSessionConfiguration.default
        super.init()
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }
    
    private func sendRequest(_ request:URLRequest, callback:@escaping (URL?, URLResponse?, Error?)->(Void)) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: request) { (url:URL?, res:URLResponse?, err:Error?) -> Void in
            if let error = err {
                print("SNNet ### error=\(error)")
                callback(url, res, err)
            } else {
                guard let hres = res as? HTTPURLResponse else {
                    print("SNNet ### not HTTP Response=\(String(describing: res))")
                    // NOTE: Probably never happens
                    return
                }
                if (200..<300).contains(hres.statusCode) {
                    callback(url, res, nil)
                } else {
                    let netError = SNFetchError(res: hres)
                    print("SNNet ### http error \(netError)")
                    callback(url, res, netError)
                }
            }
        }
        task.resume()
        return task
    }

    private func url(from path:String) -> URL? {
        if SNFetch.regex.matches(in: path, options: NSRegularExpression.MatchingOptions(), range: NSMakeRange(0, path.count)).count > 0 {
            return URL(string: path)!
        }
        return root.appendingPathComponent(path)
    }
    
    private func request(_ method:String, path:String, params:[String:String]? = nil, headers:[String:String] = [String:String](), callback:@escaping (URL?, URLResponse?, Error?)->(Void)) -> URLSessionDownloadTask? {
        guard let url = url(from: path) else {
            print("SNNet Invalid URL:\(path)")
            return nil
        }
        var query:String?
        if let p = params {
            query = p.map { (key, value) in "\(key)=\(SNFetch.encode(value))" }.joined(separator: "&")
        }
        
        var request:URLRequest
        if let q = query, method == "GET" {
            let urlGet = URL(string: url.absoluteString + "?\(q)")!
            request = URLRequest(url: urlGet)
            print("SNNet \(method) url=\(urlGet)")
        } else {
            request = URLRequest(url: url)
            print("SNNet \(method) url=\(url) +\(query ?? "")")
        }
        
        request.httpMethod = method
        if let data = query?.data(using: String.Encoding.utf8), method != "GET" {
            request.httpBody = data
            request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        for (key,value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key,value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return sendRequest(request, callback: callback)
    }
    
    @discardableResult
    func get(_ path:String, params:[String:String]? = nil, headers:[String:String] = [String:String](),  callback:@escaping (URL?, URLResponse?, Error?)->(Void)) -> URLSessionDownloadTask? {
        return request("GET", path: path, params:params, headers:headers, callback:callback)
    }

    @discardableResult
    func put(_ path:String, params:[String:String]? = nil, headers:[String:String] = [String:String](),  callback:@escaping (URL?, URLResponse?, Error?)->(Void)) -> URLSessionDownloadTask? {
        return request("PUT", path: path, params:params, headers:headers, callback:callback)
    }

    @discardableResult
    func get(_ path:String, params:[String:String]? = nil, headers:[String:String] = [String:String](),  callback:@escaping ([String:Any]?, URLResponse?, Error?)->(Void)) -> URLSessionDownloadTask? {
        return request("GET", path: path, params:params, headers:headers) { url, res, error in
            if let error = error {
                callback(nil, res, error)
                return
            }
            
            guard
                let url = url,
                let data = try? Data(contentsOf: url),
                let json_ = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                let json = json_
                else {
                    callback(nil, nil, nil) // LAZY implementation
                    return
            }
            callback(json, res, nil)
        }
    }
    
    @discardableResult
    func post(_ path:String, fileData:Data, params:[String:String], callback:@escaping (URL?, URLResponse?, Error?)->(Void)) -> URLSessionDownloadTask? {
        guard let url = url(from: path) else {
            print("SNNet Invalid URL:\(path)")
            // BUGBUG: callback with an error
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        var body = ""
        for (name, value) in params {
            body += "\r\n--\(SNFetch.boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            body += value
        }
        body += "\r\n--\(SNFetch.boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"file\"\r\n\r\n"
        
        //print("SNNet FILE body:\(body)")
        var data = body.data(using: String.Encoding.utf8)!
        
        data.append(fileData)
        data.append("\r\n--\(SNFetch.boundary)--\r\n".data(using: String.Encoding.utf8)!)
        
        request.httpBody = data
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("multipart/form-data; boundary=\(SNFetch.boundary)", forHTTPHeaderField: "Content-Type")
        
        return sendRequest(request, callback: callback)
    }
}

extension SNFetch: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        //NotificationCenter.default.post(name: .SNNetDidSentBytes, object: task)
    }
}
