public enum Metav1 {
    public typealias Metadata = Octelium_Api_Main_Meta_V1_Metadata
    public typealias CommonListOptions = Octelium_Api_Main_Meta_V1_CommonListOptions
    public typealias ListResponseMeta = Octelium_Api_Main_Meta_V1_ListResponseMeta
    public typealias DualStackNetwork = Octelium_Api_Main_Meta_V1_DualStackNetwork
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

public enum Mobilev1 {
    public typealias Config = Octelium_Api_Client_Mobile_V1_Config
    public typealias GetInfoRequest = Octelium_Api_Client_Mobile_V1_GetInfoRequest
    public typealias GetInfoResponse = Octelium_Api_Client_Mobile_V1_GetInfoResponse
    public typealias CompleteAuthenticationRequest = Octelium_Api_Client_Mobile_V1_CompleteAuthenticationRequest
    public typealias SetNetworkStateRequest = Octelium_Api_Client_Mobile_V1_SetNetworkStateRequest
    public typealias SetNetworkStateResponse = Octelium_Api_Client_Mobile_V1_SetNetworkStateResponse
    public typealias TunnelConfiguration = Octelium_Api_Client_Mobile_V1_TunnelConfiguration
    public typealias PlatformRequest = Octelium_Api_Client_Mobile_V1_PlatformRequest
    public typealias PlatformResponse = Octelium_Api_Client_Mobile_V1_PlatformResponse
    public typealias Log = Octelium_Api_Client_Mobile_V1_Log
    public typealias Event = Octelium_Api_Client_Mobile_V1_Event
}
