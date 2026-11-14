// pattern: Functional Core
// Shared platform shims for BooxBridgeCore. URLSession lives in
// FoundationNetworking on non-Apple hosts; this import must stay the only
// host-conditional in the library.

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
