// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IRoyaltyModule } from "../../../../interfaces/modules/royalty/IRoyaltyModule.sol";
import { IGraphAwareRoyaltyPolicy } from "../../../../interfaces/modules/royalty/policies/IGraphAwareRoyaltyPolicy.sol";
import { IIpRoyaltyVault } from "../../../../interfaces/modules/royalty/policies/IIpRoyaltyVault.sol";
import { Errors } from "../../../../lib/Errors.sol";
import { ProtocolPausableUpgradeable } from "../../../../pause/ProtocolPausableUpgradeable.sol";
import { IPGraphACL } from "../../../../access/IPGraphACL.sol";

/// @title Liquid Relative Percentage Royalty Policy
/// @notice Defines the logic for splitting royalties for a given ipId using a liquid relative percentage mechanism
/// @dev [CAUTION]
///      The LRP (Limited Royalty Percentage) royalty policy allows each remixed IP to receive a percentage of the
///      revenue generated by its direct derivatives. However, it is important for external developers to understand the
///      potential dilution of royalties as more derivatives are created between two IPs.
///      This dilution can reduce the earnings of the original IP creator as more layers of derivatives are added.
///
///      Example:
///      Creator 1 - Registers IP1, mints an LRP license of 10%, and sells the license to Creator 2.
///      Creator 2 - Registers IP2 as a derivative of IP1 and mints an LRP license of 20% for himself/herself.
///      Creator 2 - Registers IP3 as a derivative of IP2. Creator 2 decides to promote IP3 commercially in the market.
///      The earnings for Creator 1 are diluted because they will only receive 10% of the 20% royalties from IP3,
///      resulting in an effective royalty of 2%. If Creator 2 had chosen to promote IP2 instead, Creator 1 would
///      have earned 10% directly, avoiding this dilution. This lack of control over which IP is promoted commercially
///      means that Creator 1 is exposed to significant dilution risk under the LRP royalty policy.
///
///      In contrast, the LAP (Limited Absolute Percentage) royalty policy enforces a fixed percentage on every
///      descendant IP, protecting the original creator from dilution.
///
///      External developers considering the use of the LRP royalty policy should be aware of the potential for royalty
///      dilution and consider measures to prevent/mitigate the dilution risk or whether the LRP royalty policy is the
///      right policy for their use case.
contract RoyaltyPolicyLRP is
    IGraphAwareRoyaltyPolicy,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ProtocolPausableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @dev Storage structure for the RoyaltyPolicyLRP
    /// @param royaltyStackLRP Sum of the royalty percentages to be paid to all ancestors for LRP royalty policy
    /// @param ancestorPercentLRP The royalty percentage between an IP asset and a given ancestor for LRP royalty policy
    /// @param transferredTokenLRP Total lifetime revenue tokens transferred to a vault from a descendant IP via LRP
    /// @custom:storage-location erc7201:story-protocol.RoyaltyPolicyLRP
    struct RoyaltyPolicyLRPStorage {
        mapping(address ipId => uint32) royaltyStackLRP;
        mapping(address ipId => mapping(address ancestorIpId => uint32)) ancestorPercentLRP;
        mapping(address ipId => mapping(address ancestorIpId => mapping(address token => uint256))) transferredTokenLRP;
    }

    // keccak256(abi.encode(uint256(keccak256("story-protocol.RoyaltyPolicyLRP")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant RoyaltyPolicyLRPStorageLocation =
        0xbbe79ec88963794a251328747c07178ad16a06e9c87463d90d5d0d429fa6e700;

    /// @notice Ip graph precompile contract address
    address public constant IP_GRAPH = address(0x0101);

    /// @notice Returns the RoyaltyModule address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IRoyaltyModule public immutable ROYALTY_MODULE;

    /// @notice Returns the RoyaltyPolicyLAP address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IGraphAwareRoyaltyPolicy public immutable ROYALTY_POLICY_LAP;

    /// @notice IPGraphACL address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IPGraphACL public immutable IP_GRAPH_ACL;

    /// @dev Restricts the calls to the royalty module
    modifier onlyRoyaltyModule() {
        if (msg.sender != address(ROYALTY_MODULE)) revert Errors.RoyaltyPolicyLRP__NotRoyaltyModule();
        _;
    }

    /// @notice Constructor
    /// @param royaltyModule The RoyaltyModule address
    /// @param royaltyPolicyLAP The RoyaltyPolicyLAP address
    /// @param ipGraphAcl The IPGraphACL address
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address royaltyModule, address royaltyPolicyLAP, address ipGraphAcl) {
        if (royaltyModule == address(0)) revert Errors.RoyaltyPolicyLRP__ZeroRoyaltyModule();
        if (royaltyPolicyLAP == address(0)) revert Errors.RoyaltyPolicyLRP__ZeroRoyaltyPolicyLAP();
        if (ipGraphAcl == address(0)) revert Errors.RoyaltyPolicyLRP__ZeroIPGraphACL();

        ROYALTY_MODULE = IRoyaltyModule(royaltyModule);
        ROYALTY_POLICY_LAP = IGraphAwareRoyaltyPolicy(royaltyPolicyLAP);
        IP_GRAPH_ACL = IPGraphACL(ipGraphAcl);

        _disableInitializers();
    }

    /// @notice Initializer for this implementation contract
    /// @param accessManager The address of the protocol admin roles contract
    function initialize(address accessManager) external initializer {
        if (accessManager == address(0)) revert Errors.RoyaltyPolicyLRP__ZeroAccessManager();
        __ProtocolPausable_init(accessManager);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Executes royalty related logic on minting a license
    /// @dev Enforced to be only callable by RoyaltyModule
    /// @param ipId The ipId whose license is being minted (licensor)
    /// @param licensePercent The license percentage of the license being minted
    function onLicenseMinting(
        address ipId,
        uint32 licensePercent,
        bytes calldata
    ) external nonReentrant onlyRoyaltyModule {
        if (ROYALTY_POLICY_LAP.getPolicyRoyaltyStack(ipId) + licensePercent > ROYALTY_MODULE.maxPercent())
            revert Errors.RoyaltyPolicyLRP__AboveMaxPercent();
    }

    /// @notice Executes royalty related logic on linking to parents
    /// @dev Enforced to be only callable by RoyaltyModule
    /// @param ipId The children ipId that is being linked to parents
    /// @param parentIpIds The parent ipIds that the children ipId is being linked to
    /// @param licensesPercent The license percentage of the licenses being minted
    /// @return newRoyaltyStackLRP The royalty stack of the child ipId for LRP royalty policy
    function onLinkToParents(
        address ipId,
        address[] calldata parentIpIds,
        address[] memory licenseRoyaltyPolicies,
        uint32[] calldata licensesPercent,
        bytes calldata
    ) external nonReentrant onlyRoyaltyModule returns (uint32 newRoyaltyStackLRP) {
        IP_GRAPH_ACL.allow();
        for (uint256 i = 0; i < parentIpIds.length; i++) {
            // when a parent is linking through a different royalty policy, the royalty amount is zero
            if (licenseRoyaltyPolicies[i] == address(this)) {
                // for parents linking through LRP license, the royalty amount is set in the precompile
                _setRoyaltyLRP(ipId, parentIpIds[i], licensesPercent[i]);
            }
        }
        IP_GRAPH_ACL.disallow();

        // calculate new royalty stack
        newRoyaltyStackLRP = _getRoyaltyStackLRP(ipId);
        _getRoyaltyPolicyLRPStorage().royaltyStackLRP[ipId] = newRoyaltyStackLRP;
    }

    /// @notice Transfers to vault an amount of revenue tokens claimable via LRP royalty policy
    /// @param ipId The ipId of the IP asset
    /// @param ancestorIpId The ancestor ipId of the IP asset
    /// @param token The token address to transfer
    /// @return The amount of revenue tokens transferred
    function transferToVault(
        address ipId,
        address ancestorIpId,
        address token
    ) external whenNotPaused returns (uint256) {
        RoyaltyPolicyLRPStorage storage $ = _getRoyaltyPolicyLRPStorage();

        uint32 ancestorPercent = $.ancestorPercentLRP[ipId][ancestorIpId];
        if (ancestorPercent == 0) {
            // on the first transfer to a vault from a specific descendant the royalty between the two is set
            ancestorPercent = _getRoyaltyLRP(ipId, ancestorIpId);
            if (ancestorPercent == 0) revert Errors.RoyaltyPolicyLRP__ZeroClaimableRoyalty();
            $.ancestorPercentLRP[ipId][ancestorIpId] = ancestorPercent;
        }

        // calculate the amount to transfer
        IRoyaltyModule royaltyModule = ROYALTY_MODULE;
        uint256 totalRevenueTokens = royaltyModule.totalRevenueTokensReceived(ipId, token);
        uint256 maxAmount = (totalRevenueTokens * ancestorPercent) / royaltyModule.maxPercent();
        uint256 transferredAmount = $.transferredTokenLRP[ipId][ancestorIpId][token];
        uint256 amountToTransfer = Math.min(maxAmount - transferredAmount, IERC20(token).balanceOf(address(this)));

        // make the revenue token transfer
        $.transferredTokenLRP[ipId][ancestorIpId][token] += amountToTransfer;
        address ancestorIpRoyaltyVault = royaltyModule.ipRoyaltyVaults(ancestorIpId);
        IIpRoyaltyVault(ancestorIpRoyaltyVault).updateVaultBalance(token, amountToTransfer);
        IERC20(token).safeTransfer(ancestorIpRoyaltyVault, amountToTransfer);

        emit RevenueTransferredToVault(ipId, ancestorIpId, token, amountToTransfer);
        return amountToTransfer;
    }

    /// @notice Returns the amount of royalty tokens required to link a child to a given IP asset
    /// @param ipId The ipId of the IP asset
    /// @param licensePercent The percentage of the license
    /// @return The amount of royalty tokens required to link a child to a given IP asset
    function getPolicyRtsRequiredToLink(address ipId, uint32 licensePercent) external view returns (uint32) {
        return 0;
    }

    /// @notice Returns the LRP royalty stack for a given IP asset
    /// @param ipId The ipId to get the royalty stack for
    /// @return Sum of the royalty percentages to be paid to all ancestors for LRP royalty policy
    function getPolicyRoyaltyStack(address ipId) external view returns (uint32) {
        return _getRoyaltyPolicyLRPStorage().royaltyStackLRP[ipId];
    }

    /// @notice Returns the royalty percentage between an IP asset and its ancestors via LRP
    /// @param ipId The ipId to get the royalty for
    /// @param ancestorIpId The ancestor ipId to get the royalty for
    /// @return The royalty percentage between an IP asset and its ancestors via LRP
    function getPolicyRoyalty(address ipId, address ancestorIpId) external returns (uint32) {
        return _getRoyaltyLRP(ipId, ancestorIpId);
    }

    /// @notice Returns the total lifetime revenue tokens transferred to a vault from a descendant IP via LRP
    /// @param ipId The ipId of the IP asset
    /// @param ancestorIpId The ancestor ipId of the IP asset
    /// @param token The token address to transfer
    /// @return The total lifetime revenue tokens transferred to a vault from a descendant IP via LRP
    function getTransferredTokens(address ipId, address ancestorIpId, address token) external view returns (uint256) {
        return _getRoyaltyPolicyLRPStorage().transferredTokenLRP[ipId][ancestorIpId][token];
    }

    /// @notice Returns the royalty stack for a given IP asset for LRP royalty policy
    /// @param ipId The ipId to get the royalty stack for
    /// @return The royalty stack for a given IP asset for LRP royalty policy
    function _getRoyaltyStackLRP(address ipId) internal returns (uint32) {
        (bool success, bytes memory returnData) = IP_GRAPH.call(
            abi.encodeWithSignature("getRoyaltyStack(address,uint256)", ipId, uint256(1))
        );
        require(success, "Call failed");
        return uint32(abi.decode(returnData, (uint256)));
    }

    /// @notice Sets the LRP royalty for a given link between an IP asset and its ancestor
    /// @param ipId The ipId to set the royalty for
    /// @param parentIpId The parent ipId to set the royalty for
    /// @param royalty The LRP license royalty percentage
    function _setRoyaltyLRP(address ipId, address parentIpId, uint32 royalty) internal {
        (bool success, bytes memory returnData) = IP_GRAPH.call(
            abi.encodeWithSignature(
                "setRoyalty(address,address,uint256,uint256)",
                ipId,
                parentIpId,
                uint256(1),
                uint256(royalty)
            )
        );
        require(success, "Call failed");
    }

    /// @notice Returns the royalty percentage between an IP asset and its ancestor via royalty policy LRP
    /// @param ipId The ipId to get the royalty for
    /// @param ancestorIpId The ancestor ipId to get the royalty for
    /// @return The royalty percentage between an IP asset and its ancestor via royalty policy LRP
    function _getRoyaltyLRP(address ipId, address ancestorIpId) internal returns (uint32) {
        (bool success, bytes memory returnData) = IP_GRAPH.call(
            abi.encodeWithSignature("getRoyalty(address,address,uint256)", ipId, ancestorIpId, uint256(1))
        );
        require(success, "Call failed");
        return uint32(abi.decode(returnData, (uint256)));
    }

    /// @notice Returns the storage struct of RoyaltyPolicyLRP
    function _getRoyaltyPolicyLRPStorage() private pure returns (RoyaltyPolicyLRPStorage storage $) {
        assembly {
            $.slot := RoyaltyPolicyLRPStorageLocation
        }
    }

    /// @dev Hook to authorize the upgrade according to UUPSUpgradeable
    /// @param newImplementation The address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override restricted {}
}
