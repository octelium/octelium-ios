public enum Metav1 {
    public typealias Metadata = Octelium_Api_Main_Meta_V1_Metadata
    public typealias CommonListOptions = Octelium_Api_Main_Meta_V1_CommonListOptions
    public typealias ListResponseMeta = Octelium_Api_Main_Meta_V1_ListResponseMeta
    public typealias DualStackNetwork = Octelium_Api_Main_Meta_V1_DualStackNetwork
}

public enum Authv1 {
    public typealias SessionToken = Octelium_Api_Main_Auth_V1_SessionToken
    public typealias ClientLoginRequest = Octelium_Api_Main_Auth_V1_ClientLoginRequest
    public typealias ClientLoginResponse = Octelium_Api_Main_Auth_V1_ClientLoginResponse
    public typealias AuthenticateWithAuthenticationTokenRequest = Octelium_Api_Main_Auth_V1_AuthenticateWithAuthenticationTokenRequest
    public typealias AuthenticateWithRefreshTokenRequest = Octelium_Api_Main_Auth_V1_AuthenticateWithRefreshTokenRequest
    public typealias LogoutRequest = Octelium_Api_Main_Auth_V1_LogoutRequest
    public typealias LogoutResponse = Octelium_Api_Main_Auth_V1_LogoutResponse
    public typealias RegisterDeviceBeginRequest = Octelium_Api_Main_Auth_V1_RegisterDeviceBeginRequest
    public typealias RegisterDeviceBeginResponse = Octelium_Api_Main_Auth_V1_RegisterDeviceBeginResponse
    public typealias RegisterDeviceFinishRequest = Octelium_Api_Main_Auth_V1_RegisterDeviceFinishRequest
    public typealias RegisterDeviceFinishResponse = Octelium_Api_Main_Auth_V1_RegisterDeviceFinishResponse
}

public enum Userv1 {
    public typealias GetStatusRequest = Octelium_Api_Main_User_V1_GetStatusRequest
    public typealias GetStatusResponse = Octelium_Api_Main_User_V1_GetStatusResponse
    public typealias Service = Octelium_Api_Main_User_V1_Service
    public typealias ServiceList = Octelium_Api_Main_User_V1_ServiceList
    public typealias ListServiceOptions = Octelium_Api_Main_User_V1_ListServiceOptions
    public typealias Namespace = Octelium_Api_Main_User_V1_Namespace
    public typealias NamespaceList = Octelium_Api_Main_User_V1_NamespaceList
    public typealias ListNamespaceOptions = Octelium_Api_Main_User_V1_ListNamespaceOptions
    public typealias ConnectRequest = Octelium_Api_Main_User_V1_ConnectRequest
    public typealias ConnectResponse = Octelium_Api_Main_User_V1_ConnectResponse
    public typealias ConnectionState = Octelium_Api_Main_User_V1_ConnectionState
    public typealias Gateway = Octelium_Api_Main_User_V1_Gateway
    public typealias DNS = Octelium_Api_Main_User_V1_DNS
    public typealias DisconnectRequest = Octelium_Api_Main_User_V1_DisconnectRequest
    public typealias DisconnectResponse = Octelium_Api_Main_User_V1_DisconnectResponse
}

public enum Daemonv1 {
    public typealias GetStatusRequest = Octelium_Api_Client_Daemon_V1_GetStatusRequest
    public typealias GetStatusResponse = Octelium_Api_Client_Daemon_V1_GetStatusResponse
    public typealias DomainState = Octelium_Api_Client_Daemon_V1_DomainState
    public typealias AuthenticationStatus = Octelium_Api_Client_Daemon_V1_AuthenticationStatus
    public typealias ConnectionStatus = Octelium_Api_Client_Daemon_V1_ConnectionStatus
    public typealias Operation = Octelium_Api_Client_Daemon_V1_Operation
    public typealias Action = Octelium_Api_Client_Daemon_V1_Action
    public typealias Error = Octelium_Api_Client_Daemon_V1_Error
    public typealias AuthenticateRequest = Octelium_Api_Client_Daemon_V1_AuthenticateRequest
    public typealias ConnectRequest = Octelium_Api_Client_Daemon_V1_ConnectRequest
    public typealias DisconnectRequest = Octelium_Api_Client_Daemon_V1_DisconnectRequest
    public typealias LogoutRequest = Octelium_Api_Client_Daemon_V1_LogoutRequest
    public typealias DeleteDomainRequest = Octelium_Api_Client_Daemon_V1_DeleteDomainRequest
    public typealias GetOperationRequest = Octelium_Api_Client_Daemon_V1_GetOperationRequest
    public typealias CancelOperationRequest = Octelium_Api_Client_Daemon_V1_CancelOperationRequest
    public typealias GetAPICredentialRequest = Octelium_Api_Client_Daemon_V1_GetAPICredentialRequest
    public typealias GetAPICredentialResponse = Octelium_Api_Client_Daemon_V1_GetAPICredentialResponse
    public typealias DomainSettings = Octelium_Api_Client_Daemon_V1_DomainSettings
    public typealias UpdateDomainSettingsRequest = Octelium_Api_Client_Daemon_V1_UpdateDomainSettingsRequest
    public typealias ConnectionOptions = Octelium_Api_Client_Daemon_V1_ConnectionOptions
}

public enum Configv1 {
    public typealias State = Octelium_Api_Client_Config_V1_State
}
