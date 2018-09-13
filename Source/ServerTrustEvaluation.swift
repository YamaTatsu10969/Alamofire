//
//  ServerTrustPolicy.swift
//
//  Copyright (c) 2014-2016 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// Responsible for managing the mapping of `ServerTrustEvaluating` values to given hosts.
open class ServerTrustManager {
    /// Determines whether all hosts for this `ServerTrustManager` must be evaluated. Defaults to `true`.
    public let allHostsMustBeEvaluated: Bool
    
    /// The dictionary of policies mapped to a particular host.
    public let evaluators: [String: ServerTrustEvaluating]

    /// Initializes the `ServerTrustManager` instance with the given evaluators.
    ///
    /// Since different servers and web services can have different leaf certificates, intermediate and even root
    /// certficates, it is important to have the flexibility to specify evaluation policies on a per host basis. This
    /// allows for scenarios such as using default evaluation for host1, certificate pinning for host2, public key
    /// pinning for host3 and disabling evaluation for host4.
    ///
    /// - Parameters:
    ///   - allHostsMustBeEvaluated: The value determining whether all hosts for this instance must be evaluated.
    ///                              Defaults to `true`.
    ///   - evaluators:              A dictionary of evaluators mappend to hosts.
    public init(allHostsMustBeEvaluated: Bool = true, evaluators: [String: ServerTrustEvaluating]) {
        self.allHostsMustBeEvaluated = allHostsMustBeEvaluated
        self.evaluators = evaluators
    }
    
    /// Returns the `ServerTrustEvaluating` value for the given host, if one is set.
    ///
    /// By default, this method will return the policy that perfectly matches the given host. Subclasses could override
    /// this method and implement more complex mapping implementations such as wildcards.
    ///
    /// - Parameter host: The host to use when searching for a matching policy.
    /// - Returns:        The `ServerTrustEvaluating` value for the given host if found, `nil` otherwise.
    /// - Throws: `AFError.serverTrustEvaluationFailed` if `allHostsMustBeEvaluated` is `true` and no matching
    ///           evaluators are found.
    open func serverTrustEvaluator(forHost host: String) throws -> ServerTrustEvaluating? {
        guard let evaluator = evaluators[host] else {
            if allHostsMustBeEvaluated {
                throw AFError.serverTrustEvaluationFailed(reason: .noRequiredEvaluator(host: host))
            }
            
            return nil
        }
        
        return evaluator
    }
}


/// A protocol describing the API used to evaluate server trusts.
public protocol ServerTrustEvaluating {
    #if os(Linux)
    // Implement this once Linux has API for evaluating server trusts.
    #else
    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: A `Bool` indicating whether the evaluator considers the `SecTrust` value valid for `host`.
    /// - Throws:  An `AFError.serverTrustEvaluationFailed` with an associated `ServerTrustFailureReason`.
    func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool
    #endif
}

extension Array where Element == ServerTrustEvaluating {
    #if os(Linux)
    // Add this same convenience method for Linux.
    #else
    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: Whether or not the evaluator considers the `SecTrust` value valid for `host`.
    func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        for evaluator in self {
            guard try evaluator.evaluate(trust, forHost: host) else { return false }
        }

        return true
    }
    #endif
}

// MARK: - Server Trust Evaluators

/// An evaluator which uses the default server trust evaluation while allowing you to control whether to validate the
/// host provided by the challenge. Applications are encouraged to always validate the host in production environments
/// to guarantee the validity of the server's certificate chain.
public final class DefaultTrustEvaluator: ServerTrustEvaluating {
    private let validateHost: Bool

    /// Creates a `DefaultTrustEvalutor`.
    ///
    /// - Parameter validateHost: Determines whether or not the evaluator should validate the host. Defaults to `true`.
    public init(validateHost: Bool = true) {
        self.validateHost = validateHost
    }

    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: Whether or not the evaluator considers the `SecTrust` value valid for `host`.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        try trust.validate(policy: .default) { (status, result) in
            AFError.serverTrustEvaluationFailed(reason: .defaultEvaluationFailed(output: .init(host, trust, status, result)))
        }
        
        if validateHost {
            try trust.validate(policy: .hostname(host)) { (status, result) in
                AFError.serverTrustEvaluationFailed(reason: .hostValidationFailed(output: .init(host, trust, status, result)))
            }
        }
        
        return true
    }
}

/// An evaluator which Uses the default and revoked server trust evaluations allowing you to control whether to validate
/// the host provided by the challenge as well as specify the revocation flags for testing for revoked certificates.
/// Apple platforms did not start testing for revoked certificates automatically until iOS 10.1, macOS 10.12 and tvOS
/// 10.1 which is demonstrated in our TLS tests. Applications are encouraged to always validate the host in production
/// environments to guarantee the validity of the server's certificate chain.
public final class RevocationTrustEvaluator: ServerTrustEvaluating {
    /// Represents the options to be use when evaluating the status of a certificate.
    /// Only Revocation Policy Constants are valid, and can be found in [Apple's documentation](https://developer.apple.com/documentation/security/certificate_key_and_trust_services/policies/1563600-revocation_policy_constants).
    public struct Options: OptionSet {
        /// Perform revocation checking using the CRL (Certification Revocation List) method.
        public static let crl = Options(rawValue: kSecRevocationCRLMethod)
        /// Consult only locally cached replies; do not use network access.
        public static let networkAccessDisabled = Options(rawValue: kSecRevocationNetworkAccessDisabled)
        /// Perform revocation checking using OCSP (Online Certificate Status Protocol).
        public static let ocsp = Options(rawValue: kSecRevocationOCSPMethod)
        /// Prefer CRL revocation checking over OCSP; by default, OCSP is preferred.
        public static let preferCRL = Options(rawValue: kSecRevocationPreferCRL)
        /// Require a positive response to pass the policy. If the flag is not set, revocation checking is done on a
        /// "best attempt" basis, where failure to reach the server is not considered fatal.
        public static let requirePositiveResponse = Options(rawValue: kSecRevocationRequirePositiveResponse)
        /// Perform either OCSP or CRL checking. The checking is performed according to the method(s) specified in the
        /// certificate and the value of `preferCRL`.
        public static let any = Options(rawValue: kSecRevocationUseAnyAvailableMethod)
        
        /// The raw value of the option.
        public let rawValue: CFOptionFlags

        /// Creates an `Options` value with the given `CFOptionFlags`.
        ///
        /// - Parameter rawValue: The `CFOptionFlags` value to initialize with.
        public init(rawValue: CFOptionFlags) {
            self.rawValue = rawValue
        }
    }

    private let validateHost: Bool
    private let options: Options

    /// Creates a `RevocationTrustEvaluator`
    ///
    /// - Parameters:
    ///   - options:      The `Options` to use to check the revocation status of the certificate. Defaults to `.any`.
    ///   - validateHost: Determines whether or not the evaluator should validate the host. Defaults to `true`.
    public init(options: Options = .any, validateHost: Bool = true) {
        self.validateHost = validateHost
        self.options = options
    }

    public func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        try trust.validate(policy: .default) { (status, result) in
            AFError.serverTrustEvaluationFailed(reason: .defaultEvaluationFailed(output: .init(host, trust, status, result)))
        }
        
        
        if validateHost {
            try trust.validate(policy: .hostname(host)) { (status, result) in
                AFError.serverTrustEvaluationFailed(reason: .hostValidationFailed(output: .init(host, trust, status, result)))
            }
        }
        
        try trust.validate(policy: .revocation(options: options)) { (status, result) in
            AFError.serverTrustEvaluationFailed(reason: .revocationCheckFailed(output: .init(host, trust, status, result), options: options))
        }

        return true
    }
}

/// Uses the pinned certificates to validate the server trust. The server trust is considered valid if one of the pinned
/// certificates match one of the server certificates. By validating both the certificate chain and host, certificate
/// pinning provides a very secure form of server trust validation mitigating most, if not all, MITM attacks.
/// Applications are encouraged to always validate the host and require a valid certificate chain in production
/// environments.
public final class PinnedCertificatesTrustEvaluator: ServerTrustEvaluating {
    private let certificates: [SecCertificate]
    private let validateCertificateChain: Bool
    private let validateHost: Bool

    /// Creates a `PinnedCertificatesTrustEvaluator`.
    ///
    /// - Parameters:
    ///   - certificates:             The certificates to use to evalute the trust. Defaults to all `cer`, `crt`, and
    ///                               `der` certificates in `Bundle.main`.
    ///   - validateCertificateChain: Determines whether the certificate chain should be evaluated or just the given
    ///                               certificate.
    ///   - validateHost:             Determines whether or not the evaluator should validate the host. Defaults to
    ///                               `true`.
    public init(certificates: [SecCertificate] = Bundle.main.certificates,
                validateCertificateChain: Bool = true,
                validateHost: Bool = true) {
        self.certificates = certificates
        self.validateCertificateChain = validateCertificateChain
        self.validateHost = validateHost
    }

    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: Whether or not the evaluator considers the `SecTrust` value valid for `host`.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        // TODO: Throw error for empty certificates array.
        
        if validateHost {
            try trust.validate(policy: .hostname(host)) { (status, result) in
                AFError.serverTrustEvaluationFailed(reason: .hostValidationFailed(output: .init(host, trust, status, result)))
            }
        }
        
        if validateCertificateChain {
            try trust.setAnchorCertificates(certificates)
            return try trust.isValid { (status, result) in
                AFError.serverTrustEvaluationFailed(reason: .certificateChainValidationFailed(output: .init(host, trust, status, result)))
            }
        } else {
            let serverCertificatesData = Set(trust.certificateData)
            let pinnedCertificatesData = Set(certificates.data)
            let certificatesPinned = !serverCertificatesData.isDisjoint(with: pinnedCertificatesData)
            if !certificatesPinned {
                throw AFError.serverTrustEvaluationFailed(reason: .certificatePinningFailed(host: host, trust: trust, pinnedCertificates: certificates, serverCertificates: trust.certificates))
            }
            
            return certificatesPinned
        }
    }
}

/// Uses the pinned public keys to validate the server trust. The server trust is considered valid if one of the pinned
/// public keys match one of the server certificate public keys. By validating both the certificate chain and host,
/// public key pinning provides a very secure form of server trust validation mitigating most, if not all, MITM attacks.
/// Applications are encouraged to always validate the host and require a valid certificate chain in production
/// environments.
public final class PublicKeysTrustEvaluator: ServerTrustEvaluating {
    private let keys: [SecKey]
    private let validateCertificateChain: Bool
    private let validateHost: Bool

    /// Creates a `PublicKeysTrustEvaluator`.
    ///
    /// - Parameters:
    ///   - keys:                     The public keys to use to evaluate the trust. Defaults to the public keys of all
    ///                               `cer`, `crt`, and `der` certificates in `Bundle.main`.
    ///   - validateCertificateChain: Determines whether the certificate chain should be evaluated.
    ///   - validateHost:             Determines whether or not the evaluator should validate the host. Defaults to
    ///                               `true`.
    public init(keys: [SecKey] = Bundle.main.publicKeys,
                validateCertificateChain: Bool = true,
                validateHost: Bool = true) {
        self.keys = keys
        self.validateCertificateChain = validateCertificateChain
        self.validateHost = validateHost
    }

    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: Whether or not the evaluator considers the `SecTrust` value valid for `host`.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        if validateHost {
            try trust.validate(policy: .hostname(host)) { (status, result) in
                AFError.serverTrustEvaluationFailed(reason: .hostValidationFailed(output: .init(host, trust, status, result)))
            }
        }
        
        if validateCertificateChain {
            // TODO: Real certificate chain evaluation.
//            try trust.setAnchorCertificates(certificates)
//            return try trust.isValid { (status, result) in
//                AFError.serverTrustEvaluationFailed(reason: .certificateChainValidationFailed(output: .init(host, trust, status, result)))
//            }
        }
        
        let keysPinned: Bool = {
            for serverPublicKey in trust.publicKeys as [AnyHashable] {
                for pinnedPublicKey in keys as [AnyHashable] {
                    if serverPublicKey == pinnedPublicKey {
                        return true
                    }
                }
            }
            return false
        }()
        
        if !keysPinned {
            throw AFError.serverTrustEvaluationFailed(reason: .publicKeyPinningFailed(host: host, trust: trust, pinnedKeys: keys, serverKeys: trust.publicKeys))
        }
        
        return keysPinned
    }
}

/// Uses the provided evaluators to validate the server trust. The trust is only considered valid if all of the
/// evaluators consider it valid.
public final class CompositeTrustEvaluator: ServerTrustEvaluating {
    private let evaluators: [ServerTrustEvaluating]

    /// Creates a `CompositeTrustEvaluator`.
    ///
    /// - Parameter evaluators: The `ServerTrustEvaluating` values used to evaluate the server trust.
    public init(evaluators: [ServerTrustEvaluating]) {
        self.evaluators = evaluators
    }

    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: Whether or not the evaluator considers the `SecTrust` value valid for `host`.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        return try evaluators.evaluate(trust, forHost: host)
    }
}

/// Disables all evaluation which in turn will always consider any server trust as valid.
public final class DisabledEvaluator: ServerTrustEvaluating {
    public init() { }

    /// Evaluates the given `SecTrust` value for the given `host`.
    ///
    /// - Parameters:
    ///   - trust: The `SecTrust` value to evaluate.
    ///   - host:  The host for which to evaluate the `SecTrust` value.
    /// - Returns: Whether or not the evaluator considers the `SecTrust` value valid for `host`.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws -> Bool {
        return true
    }
}

public extension Bundle {
    /// Returns all valid `cer`, `crt`, and `der` certificates in the bundle.
    var certificates: [SecCertificate] {
        return paths(forResourcesOfTypes: [".cer", ".CER", ".crt", ".CRT", ".der", ".DER"]).compactMap { path in
            guard
                let certificateData = try? Data(contentsOf: URL(fileURLWithPath: path)) as CFData,
                let certificate = SecCertificateCreateWithData(nil, certificateData) else { return nil }

            return certificate
        }
    }

    /// Returns all public keys for the valid certificates in the bundle.
    var publicKeys: [SecKey] {
        return certificates.compactMap { $0.publicKey }
    }

    /// Returns all pathnames for the resources identified by the provided file extensions.
    ///
    /// - Parameter types: The filename extensions locate.
    /// - Returns:         All pathnames for the given filename extensions.
    func paths(forResourcesOfTypes types: [String]) -> [String] {
        return Array(Set(types.flatMap { paths(forResourcesOfType: $0, inDirectory: nil) }))
    }
}

public extension SecTrust {
    /// Evaluates `self` and returns `true` if the evaluation succeeds with a value of `.unspecified` or `.proceed`.
    var isValid: Bool {
        var result = SecTrustResultType.invalid
        let status = SecTrustEvaluate(self, &result)

        return (status.isSuccess) ? (result == .unspecified || result == .proceed) : false
    }
    
    @discardableResult
    func validate(policy: SecPolicy, errorProducer: (_ status: OSStatus, _ result: SecTrustResultType) -> Error) throws -> Bool {
        return try apply(policy: policy).isValid(errorProducer: errorProducer)
    }
    
    @discardableResult
    func isValid(errorProducer: (_ status: OSStatus, _ result: SecTrustResultType) -> Error) throws -> Bool {
        var result = SecTrustResultType.invalid
        let status = SecTrustEvaluate(self, &result)
        
        guard status == errSecSuccess && (result == .unspecified || result == .proceed) else {
            throw errorProducer(status, result)
        }
        
        return true
    }
    
    func apply(policy: SecPolicy) throws -> SecTrust {
        let status = SecTrustSetPolicies(self, policy)
        
        guard status.isSuccess else {
            throw AFError.serverTrustEvaluationFailed(reason: .policyApplicationFailed(trust: self, policy: policy))
        }
        
        return self
    }
    
    func setAnchorCertificates(_ certificates: [SecCertificate]) throws {
        guard SecTrustSetAnchorCertificates(self, certificates as CFArray).isSuccess else {
            // TODO: Throw error.
            return
        }
        
        guard SecTrustSetAnchorCertificatesOnly(self, true).isSuccess else {
            return
        }
    }

    /// The public keys contained in `self`.
    var publicKeys: [SecKey] {
        return (0..<SecTrustGetCertificateCount(self)).compactMap { index in
            return SecTrustGetCertificateAtIndex(self, index)?.publicKey
        }
    }

    /// The `Data` values for all certificates contained in `self`.
    var certificateData: [Data] {
        return certificates.data
    }
    
    var certificates: [SecCertificate] {
        return (0..<SecTrustGetCertificateCount(self)).compactMap { index in
            SecTrustGetCertificateAtIndex(self, index)
        }
    }
}

extension SecPolicy {
    static let `default` = SecPolicyCreateSSL(true, nil)
    static func hostname(_ hostname: String) -> SecPolicy {
        return SecPolicyCreateSSL(true, hostname as CFString)
    }
    static func revocation(options: RevocationTrustEvaluator.Options) throws -> SecPolicy {
        guard let policy = SecPolicyCreateRevocation(options.rawValue) else {
            throw AFError.serverTrustEvaluationFailed(reason: .revocationPolicyCreationFailed)
        }
        
        return policy
    }
}

public extension Array where Element == SecCertificate {
    /// All `Data` values for the contained `SecCertificate` values.
    var data: [Data] {
        return map { SecCertificateCopyData($0) as Data }
    }
}

public extension SecCertificate {
    /// The public key for `self`, if it can be extracted.
    var publicKey: SecKey? {
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let trustCreationStatus = SecTrustCreateWithCertificates(self, policy, &trust)

        guard let createdTrust = trust, trustCreationStatus == errSecSuccess else { return nil }

        return SecTrustCopyPublicKey(createdTrust)
    }
}

extension OSStatus {
    var isSuccess: Bool { return self == errSecSuccess }
}