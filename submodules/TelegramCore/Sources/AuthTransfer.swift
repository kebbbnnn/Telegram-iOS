import Foundation
import Postbox
import TelegramApi
import SyncCore
import SwiftSignalKit

public struct AuthTransferExportedToken {
    public let value: Data
    public let validUntil: Int32
}

public struct AuthTransferTokenInfo {
    public let datacenterId: Int32
    public let authKeyId: Int64
    public let deviceModel: String
    public let platform: String
    public let systemVersion: String
    public let apiId: Int32
    public let appName: String
    public let appVersion: String
    public let ip: String
    public let region: String
}

public enum ExportAuthTransferTokenError {
    case generic
}

public enum ExportAuthTransferTokenResult {
    case displayToken(AuthTransferExportedToken)
    case changeAccountAndRetry(UnauthorizedAccount)
    case loggedIn
}

public func exportAuthTransferToken(accountManager: AccountManager, account: UnauthorizedAccount, syncContacts: Bool) -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> {
    return account.network.request(Api.functions.auth.exportLoginToken(apiId: account.networkArguments.apiId, apiHash: account.networkArguments.apiHash))
    |> mapError { _ -> ExportAuthTransferTokenError in
        return .generic
    }
    |> mapToSignal { result -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> in
        switch result {
        case let .loginToken(expires, token):
            return .single(.displayToken(AuthTransferExportedToken(value: token.makeData(), validUntil: expires)))
        case let .loginTokenMigrateTo(dcId, token):
            let updatedAccount = account.changedMasterDatacenterId(accountManager: accountManager, masterDatacenterId: dcId)
            return updatedAccount
            |> castError(ExportAuthTransferTokenError.self)
            |> mapToSignal { updatedAccount -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> in
                return updatedAccount.network.request(Api.functions.auth.importLoginToken(token: token))
                |> mapError { _ -> ExportAuthTransferTokenError in
                    return .generic
                }
                |> mapToSignal { result -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> in
                    switch result {
                    case let .loginTokenSuccess(authorization):
                        switch authorization {
                        case let .authorization(_, _, user):
                            return updatedAccount.postbox.transaction { transaction -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> in
                                let user = TelegramUser(user: user)
                                let state = AuthorizedAccountState(isTestingEnvironment: updatedAccount.testingEnvironment, masterDatacenterId: updatedAccount.masterDatacenterId, peerId: user.id, state: nil)
                                initializedAppSettingsAfterLogin(transaction: transaction, appVersion: updatedAccount.networkArguments.appVersion, syncContacts: syncContacts)
                                transaction.setState(state)
                                return accountManager.transaction { transaction -> ExportAuthTransferTokenResult in
                                    switchToAuthorizedAccount(transaction: transaction, account: updatedAccount)
                                    return .loggedIn
                                }
                                |> castError(ExportAuthTransferTokenError.self)
                            }
                            |> castError(ExportAuthTransferTokenError.self)
                            |> switchToLatest
                        default:
                            return .fail(.generic)
                        }
                    default:
                        return .single(.changeAccountAndRetry(updatedAccount))
                    }
                }
            }
        case let .loginTokenSuccess(authorization):
            switch authorization {
            case let .authorization(_, _, user):
                return account.postbox.transaction { transaction -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> in
                    let user = TelegramUser(user: user)
                    let state = AuthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, peerId: user.id, state: nil)
                    initializedAppSettingsAfterLogin(transaction: transaction, appVersion: account.networkArguments.appVersion, syncContacts: syncContacts)
                    transaction.setState(state)
                    return accountManager.transaction { transaction -> ExportAuthTransferTokenResult in
                        switchToAuthorizedAccount(transaction: transaction, account: account)
                        return .loggedIn
                    }
                    |> castError(ExportAuthTransferTokenError.self)
                }
                |> castError(ExportAuthTransferTokenError.self)
                |> switchToLatest
            case let .authorizationSignUpRequired:
                return .fail(.generic)
            }
        }
    }
}

public enum GetAuthTransferTokenInfoError {
    case generic
    case invalid
    case expired
    case alreadyAccepted
}

public func getAuthTransferTokenInfo(network: Network, token: Data) -> Signal<AuthTransferTokenInfo, GetAuthTransferTokenInfoError> {
    return network.request(Api.functions.auth.checkLoginToken(token: Buffer(data: token)))
    |> mapError { error -> GetAuthTransferTokenInfoError in
        switch error.errorDescription {
        case "AUTH_TOKEN_INVALID":
            return .invalid
        case "AUTH_TOKEN_EXPIRED":
            return .expired
        case "AUTH_TOKEN_ALREADY_ACCEPTED":
            return .alreadyAccepted
        default:
            return .generic
        }
    }
    |> map { result -> AuthTransferTokenInfo in
        switch result {
        case let .loginTokenInfo(dcId, authKeyId, deviceModel, platform, systemVersion, apiId, appName, appVersion, ip, region):
            return AuthTransferTokenInfo(datacenterId: dcId, authKeyId: authKeyId, deviceModel: deviceModel, platform: platform, systemVersion: systemVersion, apiId: apiId, appName: appName, appVersion: appVersion, ip: ip, region: region)
        }
    }
}

public enum ApproveAuthTransferTokenError {
    case generic
}

public func approveAuthTransferToken(account: Account, token: Data) -> Signal<Never, ApproveAuthTransferTokenError> {
    return account.network.request(Api.functions.auth.acceptLoginToken(token: Buffer(data: token)))
    |> mapError { _ -> ApproveAuthTransferTokenError in
        return .generic
    }
    |> mapToSignal { updates -> Signal<Never, ApproveAuthTransferTokenError> in
        account.stateManager.addUpdates(updates)
        return .complete()
    }
}
