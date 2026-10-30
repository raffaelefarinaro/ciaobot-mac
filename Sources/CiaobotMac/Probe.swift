import Foundation

final class Probe: NSObject, URLSessionDataDelegate {
    static let maximumResponseBytes = 64 * 1024
    private var body = Data()
    private var completion: ((Bool) -> Void)?

    static func valid(status: Int, data: Data) -> Bool {
        guard (200...299).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["startup_id"] as? String else { return false }
        return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= Self.maximumResponseBytes - body.count else {
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && Self.valid(status: status, data: body)
        let callback = completion
        completion = nil
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { callback?(ok) }
    }

    func check(_ origin: Origin, configuration: URLSessionConfiguration = .ephemeral, completion: @escaping (Bool) -> Void) {
        // A fresh delegate owns each request's bounded buffer and callback.
        let delegate = Probe()
        delegate.completion = completion
        let config = configuration.copy() as! URLSessionConfiguration
        // The probe is an identity-shape check, never an authenticated
        // request. Drop anything a caller-supplied configuration could use to
        // attach a cookie or credential implicitly.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.httpAdditionalHeaders = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = min(config.timeoutIntervalForRequest, 8)
        config.timeoutIntervalForResource = min(config.timeoutIntervalForResource, 10)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: origin.url.appendingPathComponent("api/startup-status"))
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request).resume()
    }
}
