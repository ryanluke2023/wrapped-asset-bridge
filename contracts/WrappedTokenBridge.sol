// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LzLib} from "@layerzerolabs/solidity-examples/contracts/libraries/LzLib.sol";
import {TokenBridgeBase} from "./TokenBridgeBase.sol";
import {IWrappedERC20} from "./interfaces/IWrappedERC20.sol";

/// @dev Mints a wrapped token when a message received from a remote chain and burns a wrapped token when bridging to a remote chain
contract WrappedTokenBridge is TokenBridgeBase {
    /// @notice Tokens that can be bridged
    /// @dev [local token] => [remote chain] => [remote token]
    mapping(address => mapping(uint16 => address)) public localToRemote;

    /// @notice Tokens that can be bridged
    /// @dev [remote token] => [remote chain] => [local token]
    mapping(address => mapping(uint16 => address)) public remoteToLocal;

    /// @notice Total value bridged per token and remote chains
    /// @dev [remote chain] => [remote token] => [bridged amount]
    mapping(uint16 => mapping(address => uint)) public totalValueLocked;

    event WrapToken(address localToken, address remoteToken, uint16 remoteChainId, address to, uint amount);
    event UnwrapToken(address localToken, address remoteToken, uint16 remoteChainId, address to, uint amount);
    event RegisterTokens(address localToken, uint16 remoteChainId, address remoteToken);

    constructor(address _endpoint) TokenBridgeBase(_endpoint) {}

    function registerTokens(address localToken, uint16 remoteChainId, address remoteToken) external onlyOwner {
        require(localToken != address(0), "WrappedTokenBridge: invalid local token");
        require(remoteToken != address(0), "WrappedTokenBridge: invalid remote token");

        localToRemote[localToken][remoteChainId] = remoteToken;
        remoteToLocal[remoteToken][remoteChainId] = localToken;
        emit RegisterTokens(localToken, remoteChainId, remoteToken);
    }

    function estimateBridgeFee(address localToken, uint16 remoteChainId, uint amount, address to, bool unwrap, bool useZro, bytes calldata adapterParams) external view returns (uint nativeFee, uint zroFee) {
        bytes memory payload = abi.encode(PT_UNWRAP, localToRemote[localToken][remoteChainId], to, amount, unwrap);
        return lzEndpoint.estimateFees(remoteChainId, address(this), payload, useZro, adapterParams);
    }

    /// @notice Bridges `localToken` to the remote chain
    /// @dev Burns wrapped tokens and sends LZ message to the remote chain to unlock original tokens
    function bridge(address localToken, uint16 remoteChainId, uint amount, address to, bool unwrap, LzLib.CallParams calldata callParams, bytes memory adapterParams) external payable whenNotPaused(localToken) nonReentrant {
        require(localToken != address(0), "WrappedTokenBridge: invalid token");
        require(to != address(0), "WrappedTokenBridge: invalid to");
        require(amount > 0, "WrappedTokenBridge: invalid amount");
        _checkAdapterParams(remoteChainId, PT_UNWRAP, adapterParams);

        address remoteToken = localToRemote[localToken][remoteChainId];
        require(remoteToken != address(0), "WrappedTokenBridge: token is not supported");
        require(totalValueLocked[remoteChainId][remoteToken] >= amount, "WrappedTokenBridge: insufficient liquidity on the destination");

        totalValueLocked[remoteChainId][remoteToken] -= amount;
        IWrappedERC20(localToken).burn(msg.sender, amount);

        bytes memory payload = abi.encode(PT_UNWRAP, remoteToken, to, amount, unwrap);
        _lzSend(remoteChainId, payload, callParams.refundAddress, callParams.zroPaymentAddress, adapterParams, msg.value);
        emit UnwrapToken(localToken, remoteToken, remoteChainId, to, amount);
    }

    /// @notice Receives ERC20 tokens or ETH from the remote chain
    /// @dev Mints wrapped tokens in response to LZ message from the remote chain
    function _nonblockingLzReceive(uint16 srcChainId, bytes memory, uint64, bytes memory payload) internal virtual override {
        (uint8 packetType, address remoteToken, address to, uint amount) = abi.decode(payload, (uint8, address, address, uint));
        require(packetType == PT_WRAP, "WrappedTokenBridge: unknown packet type");

        address localToken = remoteToLocal[remoteToken][srcChainId];
        require(localToken != address(0), "WrappedTokenBridge: token is not supported");
        require(!globalPaused && !pausedTokens[localToken], "WrappedTokenBridge: paused");

        totalValueLocked[srcChainId][remoteToken] += amount;
        IWrappedERC20(localToken).mint(to, amount);

        emit WrapToken(localToken, remoteToken, srcChainId, to, amount);
    }
}