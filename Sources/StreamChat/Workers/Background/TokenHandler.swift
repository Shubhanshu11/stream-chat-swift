//
// Copyright © 2022 Stream.io Inc. All rights reserved.
//

import Foundation
import SwiftUI

/// The type responsible for holding and refreshing the access token.
protocol TokenHandler: AnyObject {
    /// The currently used token.
    var currentToken: Token? { get }
    
    /// The user connection provider.
    var connectionProvider: UserConnectionProvider { get set }
    
    /// Assignes the given value to the `currentToken`, propagates it to the waiters, and cancels the ongoing refresh process.
    /// - Parameter token: The token to set.
    func set(token: Token, completion: ((Error?) -> Void)?)
    
    /// Triggers the token refresh process. When refresh process is completed, updates `currentToken` with the new value and completes token waiters.
    /// - Parameter completion: The completion that will be called when the token is fetched.
    func refreshToken(completion: @escaping TokenWaiter)
    
    /// Adds the new token waiter without initiating the token refresh process.
    /// - Parameter completion: The completion that will be called when token is fetched.
    @discardableResult
    func add(tokenWaiter: @escaping TokenWaiter) -> WaiterToken
    
    /// Removes the waiter with the given token from the list of waiters.
    /// - Parameter token: The waiter's token
    func removeTokenWaiter(_ token: WaiterToken)
    
    /// Cancels all token waiters with the given error.
    /// - Parameter error: The error to cancel waiters with.
    func cancelTokenWaiters(with error: Error)
}

final class DefaultTokenHandler: TokenHandler {
    private let maximumTokenRefreshAttempts: Int
    private var retryStrategy: RetryStrategy
    private let retryTimerType: Timer.Type
    private var retryTimer: TimerControl?
    
    @Atomic private var isRefreshingToken: Bool = false
    @Atomic private var tokenWaiters: [WaiterToken: TokenWaiter] = [:]
    
    private(set) var currentToken: Token?
    
    var connectionProvider: UserConnectionProvider
    
    // MARK: - Init & Deinit
    
    init(
        connectionProvider: UserConnectionProvider,
        retryStrategy: RetryStrategy,
        maximumTokenRefreshAttempts: Int,
        timerType: Timer.Type
    ) {
        self.connectionProvider = connectionProvider
        self.retryStrategy = retryStrategy
        self.maximumTokenRefreshAttempts = maximumTokenRefreshAttempts
        self.retryTimerType = timerType
    }
    
    deinit {
        let error = ClientError.ClientHasBeenDeallocated()
        cancelTokenWaiters(with: error)
    }
    
    // MARK: - TokenHandler
    
    func set(token: Token, completion: ((Error?) -> Void)?) {
        if let userId = connectionProvider.userId, token.userId != userId {
            completion?(ClientError.InvalidToken("The token is for another user"))
            return
        }
        
        handleTokenResult(.success(token))
        completion?(nil)
    }
    
    func cancelTokenWaiters(with error: Error) {
        handleTokenResult(.failure(error))
    }
    
    func refreshToken(completion: @escaping TokenWaiter) {
        let shouldTriggerRefresh = initiateRefreshIfNotRunning()
        
        _ = add(tokenWaiter: completion)
        
        guard shouldTriggerRefresh else {
            return
        }
        
        let tokenBeforeRefresh = currentToken
        
        retry { [weak self] in
            guard let self = self else { return }
            
            // When `set(token:)` get's invoked while the ongoing token refresh process,
            // we should assign the given token and cancel the refresh flow. However, cancelling refresh flow
            // is currently not possible because `tokenProvider` is not returning the cancellable (planned for v5).
            //
            // To avoid overriding the token assinged by `set(token:)`, we store the token before the refresh
            // and compare it we with the current token when refresh is completed. If the tokens does not match,
            // it means the token was manually assigned and results from `tokenProvider` should be discarded.
            guard self.currentToken == tokenBeforeRefresh else {
                return
            }
            
            switch $0 {
            case .success(let newToken) where newToken == self.currentToken:
                let sameTokenError = """
                    Token refresh failed ❌: the old token was returned during the refresh proccess.
                    When connecting with a static token, make sure it has no expiration date.
                    When connecting with a `tokenProvider`, make sure to fetch the new token from the backend.
                """
                self.handleTokenResult(.failure(ClientError.InvalidToken(sameTokenError)))
            default:
                self.handleTokenResult($0)
            }
        }
    }
    
    @discardableResult
    func add(tokenWaiter: @escaping TokenWaiter) -> WaiterToken {
        let token: String = .newUniqueId
        
        if let token = currentToken, !isRefreshingToken {
            tokenWaiter(.success(token))
        } else {
            _tokenWaiters.mutate {
                $0[token] = tokenWaiter
            }
        }
        
        return token
    }
    
    func removeTokenWaiter(_ token: WaiterToken) {
        _tokenWaiters.mutate {
            $0[token] = nil
        }
    }
    
    // MARK: - Private
    
    private func retry(completion: @escaping (Result<Token, Error>) -> Void) {
        guard retryStrategy.consecutiveFailuresCount < maximumTokenRefreshAttempts else {
            completion(.failure(ClientError.TooManyTokenRefreshAttempts()))
            return
        }
        
        let delay = retryStrategy.consecutiveFailuresCount > 0
            ? retryStrategy.nextRetryDelay()
            : 0
                        
        retryTimer = retryTimerType.schedule(timeInterval: delay, queue: .main) { [weak self] in
            guard let self = self else { return }
                        
            self.connectionProvider.fetchToken { [weak self] in
                guard let self = self else { return }
                
                switch $0 {
                case .success(let token):
                    completion(.success(token))
                case .failure:
                    self.retryStrategy.incrementConsecutiveFailures()
                    self.retry(completion: completion)
                }
            }
        }
    }
    
    private func handleTokenResult(_ result: Result<Token, Error>) {
        switch result {
        case .success(let token):
            currentToken = token
        case .failure:
            currentToken = nil
        }
        
        retryStrategy.resetConsecutiveFailures()
        retryTimer?.cancel()
        retryTimer = nil
        
        isRefreshingToken = false
        
        _tokenWaiters.mutate {
            $0.forEach { $0.value(result) }
            $0.removeAll()
        }
    }
    
    private func initiateRefreshIfNotRunning() -> Bool {
        var initiate = false
        
        _isRefreshingToken.mutate { isRefreshingToken in
            guard !isRefreshingToken else { return }
            
            isRefreshingToken = true
            initiate = true
        }
        
        return initiate
    }
}
