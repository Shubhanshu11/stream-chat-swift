//
// Copyright © 2022 Stream.io Inc. All rights reserved.
//

@testable import StreamChat
@testable import StreamChatTestTools
import XCTest

final class TokenHandler_Tests: XCTestCase {
    var mockRetryStrategy: RetryStrategy_Spy!
    var mockTime: VirtualTime { VirtualTimeTimer.time }
    
    // MARK: - setUp, tearDown
    
    override func setUp() {
        super.setUp()
        
        mockRetryStrategy = .init()
        VirtualTimeTimer.time = .init()
    }
    
    override func tearDown() {
        VirtualTimeTimer.time = nil
        mockRetryStrategy = nil
        
        super.tearDown()
    }
    
    // MARK: - refreshToken
    
    func test_refreshToken_whenCalledMultipleTime_onlyOneRefreshProcessIsTriggered() {
        // GIVEN
        let sut = createTokenHandler()
        
        let token: Token = .unique()
        var connectionProviderCallsCount = 0
        sut.connectionProvider = .initiated(userId: token.userId) { completion in
            connectionProviderCallsCount += 1
            completion(.success(token))
        }
        
        // WHEN
        let iterations = 100
        
        var results = [Result<Token, Error>?](repeating: nil, count: iterations)

        let completionsCalled = XCTestExpectation(description: "refreshToken completions called")
        completionsCalled.expectedFulfillmentCount = iterations
                
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            sut.refreshToken {
                results[index] = $0
                completionsCalled.fulfill()
            }
        }
        
        mockTime.run()
        
        // THEN
        wait(for: [completionsCalled], timeout: defaultTimeout)
        XCTAssertTrue(results.allSatisfy { $0?.value == token })
        XCTAssertEqual(connectionProviderCallsCount, 1)
    }
    
    func test_refreshToken_whenTheSameTokenIsReturned() {
        // GIVEN
        let sut = createTokenHandler()

        let token: Token = .unique()
        sut.connectionProvider = .initiated(userId: token.userId) { $0(.success(token)) }
        sut.set(token: token) { _ in }
        
        // WHEN
        var refreshResult: Result<Token, Error>?
        sut.refreshToken { refreshResult = $0 }
        mockTime.run()
        
        // THEN
        XCTAssertTrue(refreshResult?.error is ClientError.InvalidToken)
        XCTAssertEqual(sut.currentToken, token)
    }
    
    func test_refreshToken_whenRefreshSucceeds() {
        // GIVEN
        let userId: UserId = .unique
    
        let sut = createTokenHandler()
        
        var connectionProviderCallsCount = 0
        var tokenProviderCompletion: TokenWaiter?
        sut.connectionProvider = .initiated(userId: userId) { completion in
            tokenProviderCompletion = completion
            connectionProviderCallsCount += 1
        }
        
        // WHEN
        var refreshResult: Result<Token, Error>?
        sut.refreshToken { refreshResult = $0 }
        
        var tokenWaiterResult: Result<Token, Error>?
        sut.add { tokenWaiterResult = $0 }
        
        mockTime.run(numberOfSeconds: 1)
        
        let token = Token.unique(userId: userId)
        tokenProviderCompletion?(.success(token))
        
        mockTime.run()
        
        // THEN
        XCTAssertEqual(refreshResult?.value, token)
        XCTAssertEqual(tokenWaiterResult?.value, token)
        XCTAssertEqual(sut.currentToken, token)
        XCTAssertEqual(connectionProviderCallsCount, 1)
    }
    
    func test_refreshToken_whenRefreshFails() {
        // GIVEN
        let userId: UserId = .unique
        let token: Token = .unique(userId: userId)
            
        let sut = createTokenHandler(maximumTokenRefreshAttempts: 1)
        sut.set(token: token) { _ in }
        
        var connectionProviderCallsCount = 0
        var tokenProviderCompletion: TokenWaiter?
        sut.connectionProvider = .initiated(userId: userId) { completion in
            tokenProviderCompletion = completion
            connectionProviderCallsCount += 1
        }
        
        // WHEN
        var refreshResult: Result<Token, Error>?
        sut.refreshToken { refreshResult = $0 }
        
        var tokenWaiterResult: Result<Token, Error>?
        sut.add { tokenWaiterResult = $0 }
        
        mockTime.run(numberOfSeconds: 1)
        
        let error = TestError()
        mockRetryStrategy.consecutiveFailuresCount = 1
        tokenProviderCompletion?(.failure(error))
        
        mockTime.run()
        
        // THEN
        XCTAssertEqual(connectionProviderCallsCount, 1)
        XCTAssertNotNil(refreshResult?.error)
        XCTAssertNotNil(tokenWaiterResult?.error)
        XCTAssertNil(sut.currentToken)
    }
    
    func test_refreshToken_whenAllRetryAttempsFail() {
        // GIVEN
        var connectionProviderCallsCount = 0
        
        let sut = createTokenHandler(
            connectionProvider: .initiated(userId: .unique) { [mockRetryStrategy] completion in
                mockRetryStrategy!.consecutiveFailuresCount += 1
                connectionProviderCallsCount += 1
                completion(.failure(TestError()))
            },
            maximumTokenRefreshAttempts: 3
        )
        
        // WHEN
        var refreshResult: Result<Token, Error>?
        sut.refreshToken {
            refreshResult = $0
        }
        
        XCTAssertNil(refreshResult)
        XCTAssertEqual(connectionProviderCallsCount, 0)
        mockRetryStrategy.mock_nextRetryDelay.returns(2)
        mockTime.run(numberOfSeconds: 1)
        
        XCTAssertNil(refreshResult)
        XCTAssertEqual(connectionProviderCallsCount, 1)
        mockRetryStrategy.mock_nextRetryDelay.returns(5)
        mockTime.run(numberOfSeconds: 2)

        XCTAssertNil(refreshResult)
        XCTAssertEqual(connectionProviderCallsCount, 2)
        mockRetryStrategy.mock_nextRetryDelay.returns(10)
        mockTime.run()
        
        // THEN
        XCTAssertTrue(refreshResult?.error is ClientError.TooManyTokenRefreshAttempts)
        XCTAssertEqual(connectionProviderCallsCount, 3)
    }
    
    // MARK: - set(token: )
    
    func test_setToken_whenConnectionProviderIsMissing_assignesTokenAndCompletesWaiters() {
        // GIVEN
        let sut = createTokenHandler(connectionProvider: .noCurrentUser)
        
        // WHEN
        let token = Token.unique(userId: .unique)
        let completionCalled = XCTestExpectation(description: "set(token:) completion called")
        var completionError: Error?
        sut.set(token: token) { error in
            completionCalled.fulfill()
            completionError = error
        }
        
        // THEN
        wait(for: [completionCalled], timeout: 0)
        XCTAssertEqual(sut.currentToken, token)
        XCTAssertNil(completionError)
    }
    
    func test_setToken_whenConnectionProviderIsForSameUser_assignesTokenAndCompletesWaiters() {
        // GIVEN
        let token = Token.unique(userId: .unique)
        let sut = createTokenHandler(connectionProvider: .notInitiated(userId: token.userId))
        
        // WHEN
        let completionCalled = XCTestExpectation(description: "set(token:) completion called")
        var completionError: Error?
        sut.set(token: token) { error in
            completionCalled.fulfill()
            completionError = error
        }
        
        // THEN
        wait(for: [completionCalled], timeout: 0)
        XCTAssertEqual(sut.currentToken, token)
        XCTAssertNil(completionError)
    }
    
    func test_setToken_whenConnectionProviderIsForAnotherUser_fails() {
        // GIVEN
        let sut = createTokenHandler(connectionProvider: .notInitiated(userId: .unique))
        
        // WHEN
        let completionCalled = XCTestExpectation(description: "set(token:) completion called")
        var completionError: Error?
        sut.set(token: .unique(userId: .unique)) { error in
            completionCalled.fulfill()
            completionError = error
        }
        
        // THEN
        wait(for: [completionCalled], timeout: 0)
        XCTAssertTrue(completionError is ClientError.InvalidToken)
        XCTAssertNil(sut.currentToken)
    }
    
    func test_setToken_whenRefreshFlowIsInProgress_refreshResultIsDiscarded() throws {
        // GIVEN
        let userId: UserId = .unique
        
        var tokenProviderCompletion: TokenWaiter?
        let sut = createTokenHandler(
            connectionProvider: .initiated(userId: userId) {
                tokenProviderCompletion = $0
            }
        )
        sut.refreshToken { _ in }
        
        // WHEN
        let token: Token = .unique(userId: userId)
        sut.set(token: token) { _ in }
        
        mockTime.run(numberOfSeconds: 0.5)
        
        let refreshedToken: Token = .unique(userId: userId)
        tokenProviderCompletion?(.success(refreshedToken))
        
        // THEN
        XCTAssertEqual(sut.currentToken, token)
    }
    
    // MARK: - add(tokenWaiter:)
    
    func test_addTokenWaiter_whenTokenExistsAndNotBeingRefreshed_completesWaiterImmidiately() {
        // GIVEN
        let token: Token = .unique()
        
        let sut = createTokenHandler()
        sut.set(token: token) { _ in }
        
        // WHEN
        var waiterResult: Result<Token, Error>?
        sut.add { waiterResult = $0 }
        
        // THEN
        XCTAssertEqual(waiterResult?.value, token)
    }
    
    func test_addTokenWaiter_whenTokenDoesNotExist_storesWaiterToCallLater() {
        // GIVEN
        let sut = createTokenHandler()
        
        // WHEN
        var waiterIsCalled = false
        sut.add { _ in waiterIsCalled = true }
        
        // THEN
        XCTAssertFalse(waiterIsCalled)
    }
    
    func test_addTokenWaiter_whenTokenIsBeingRefreshed_storesWaiterToCallLater() {
        // GIVEN
        let token: Token = .unique()
        
        let sut = createTokenHandler(connectionProvider: .initiated(userId: token.userId) { _ in })
        sut.set(token: token) { _ in }
        sut.refreshToken { _ in }
        
        // WHEN
        var waiterIsCalled = false
        sut.add { _ in waiterIsCalled = true }
        
        // THEN
        XCTAssertFalse(waiterIsCalled)
    }
    
    func test_addTokenWaiter_doesNotTriggerRefreshProcess() {
        // GIVEN
        let sut = createTokenHandler()
        
        var tokenProviderCalled = false
        sut.connectionProvider = .initiated(userId: .unique) { _ in
            tokenProviderCalled = true
        }
        
        // WHEN
        sut.add { _ in }
        sut.add { _ in }
        sut.add { _ in }
        
        // THEN
        AssertAsync.staysTrue(tokenProviderCalled == false)
    }
    
    // MARK: - removeTokenWaiter
    
    func test_removeTokenWaiter_waiterIsNotCalledWhenTokenIsSet() {
        // GIVEN
        let sut = createTokenHandler()
        
        var waiterCalled = false
        let token = sut.add { _ in waiterCalled = true }
        
        // WHEN
        sut.removeTokenWaiter(token)
        sut.set(token: .unique()) { _ in }
        
        // THEN
        XCTAssertFalse(waiterCalled)
    }
    
    func test_removeTokenWaiter_waiterIsNotCalledWhenTokenIsRefreshed() {
        // GIVEN
        let sut = createTokenHandler()
        
        let token = Token.unique()
        sut.connectionProvider = .initiated(userId: token.userId) {
            $0(.success(token))
        }
        
        var waiterCalled = false
        let waiterToken = sut.add { _ in waiterCalled = true }
        
        // WHEN
        let refreshCompletionCalled = XCTestExpectation(description: "completion called")
        sut.refreshToken { _ in
            refreshCompletionCalled.fulfill()
        }
        
        sut.removeTokenWaiter(waiterToken)
        
        mockTime.run()
        
        // THEN
        wait(for: [refreshCompletionCalled], timeout: defaultTimeout)
        XCTAssertFalse(waiterCalled)
    }
    
    // MARK: - cancelTokenWaiters
    
    func test_cancelTokenWaiters_cancelsWaitersWithTheGivenError() {
        // GIVEN
        let sut = createTokenHandler()
        
        let waitersCount = 5
        var tokenWaiterResults: [Result<Token, Error>] = []
        (0..<waitersCount).forEach { _ in
            sut.add { tokenWaiterResults.append($0) }
        }
        
        // WHEN
        let error = TestError()
        sut.cancelTokenWaiters(with: error)
        
        // THEN
        XCTAssertEqual(tokenWaiterResults.count, waitersCount)
        XCTAssertTrue(
            tokenWaiterResults.allSatisfy {
                $0.error as? TestError == error
            }
        )
    }
    
    func test_cancelTokenWaiters_removesWaiters() {
        // GIVEN
        let sut = createTokenHandler()
        
        var waiterCallsCount = 0
        sut.add { _ in waiterCallsCount += 1 }
        sut.cancelTokenWaiters(with: TestError())
        XCTAssertEqual(waiterCallsCount, 1)
        
        // WHEN
        sut.cancelTokenWaiters(with: TestError())
        sut.cancelTokenWaiters(with: TestError())
        sut.cancelTokenWaiters(with: TestError())

        // THEN
        XCTAssertEqual(waiterCallsCount, 1)
    }
    
    // MARK: - deinit
    
    func test_tokenHandler_whenDeallocated_cancelsTokenWaiters() throws {
        // GIVEN
        var sut: DefaultTokenHandler? = createTokenHandler()
        
        let waitersCount = 5
        var tokenWaiterResults: [Result<Token, Error>] = []
        (0..<waitersCount).forEach { _ in
            sut?.add { tokenWaiterResults.append($0) }
        }
        
        // WHEN
        sut = nil
        
        // THEN
        XCTAssertEqual(tokenWaiterResults.count, waitersCount)
        XCTAssertTrue(
            tokenWaiterResults.allSatisfy {
                $0.error is ClientError.ClientHasBeenDeallocated
            }
        )
    }
}

private extension TokenHandler_Tests {
    func createTokenHandler(
        connectionProvider: UserConnectionProvider = .noCurrentUser,
        maximumTokenRefreshAttempts: Int = 10
    ) -> DefaultTokenHandler {
        .init(
            connectionProvider: connectionProvider,
            retryStrategy: mockRetryStrategy,
            maximumTokenRefreshAttempts: maximumTokenRefreshAttempts,
            timerType: VirtualTimeTimer.self
        )
    }
}
