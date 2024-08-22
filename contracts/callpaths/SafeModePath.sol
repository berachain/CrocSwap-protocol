// SPDX-License-Identifier: GPL-3

pragma solidity 0.8.19;

import "../mixins/ProtocolAccount.sol";
import "../libraries/ProtocolCmd.sol";
import "../interfaces/ICrocMinion.sol";
import "../CrocEvents.sol";
/* @title Safe Mode Call Path.
 *
 * @notice Highly restricted callpath meant to be the sole point of entry when the dex
 *         contract has been forced into emergency safe mode. Essentially this retricts 
 *         all calls besides sudo mode admin actions. */

contract SafeModePath is ProtocolAccount {
    /* @notice Subset of highly privileged commands that are only allowed to run in sudo
     *         mode. */
    function protocolCmd(bytes calldata cmd) public {
        require(sudoMode_, "Sudo");
        uint8 cmdCode = uint8(cmd[31]);

        if (cmdCode == ProtocolCmd.COLLECT_TREASURY_CODE) {
            collectProtocol(cmd);
        } else if (cmdCode == ProtocolCmd.SET_TREASURY_CODE) {
            setTreasury(cmd);
        } else if (cmdCode == ProtocolCmd.AUTHORITY_TRANSFER_CODE) {
            transferAuthority(cmd);
        } else if (cmdCode == ProtocolCmd.HOT_OPEN_CODE) {
            setHotPathOpen(cmd);
        } else if (cmdCode == ProtocolCmd.SAFE_MODE_CODE) {
            setSafeMode(cmd);
        } else {
            revert("Invalid command");
        }
    }

    function userCmd(bytes calldata) public payable {
        revert("Emergency Safe Mode");
    }

    function setHotPathOpen(bytes calldata cmd) private {
        (, bool open) = abi.decode(cmd, (uint8, bool));
        emit CrocEvents.HotPathOpen(open);
        hotPathOpen_ = open;
    }

    function setSafeMode(bytes calldata cmd) private {
        (, bool inSafeMode) = abi.decode(cmd, (uint8, bool));
        emit CrocEvents.SafeMode(inSafeMode);
        inSafeMode_ = inSafeMode;
    }

    /* @notice Pays out the the protocol fees.
     * @param token The token for which the accumulated fees are being paid out. 
     *              (Or if 0x0 pays out native Ethereum.) */
    function collectProtocol(bytes calldata cmd) private {
        (, address token) = abi.decode(cmd, (uint8, address));

        require(block.timestamp >= treasuryStartTime_, "Treasury start");
        emit CrocEvents.ProtocolDividend(token, treasury_);
        disburseProtocolFees(treasury_, token);
    }

    /* @notice Sets the treasury address to receive protocol fees. Once set, the treasury cannot
     *         receive fees until 7 days after. */
    function setTreasury(bytes calldata cmd) private {
        (, address treasury) = abi.decode(cmd, (uint8, address));

        require(treasury != address(0) && treasury.code.length != 0, "Treasury invalid");
        treasury_ = treasury;
        treasuryStartTime_ = uint64(block.timestamp + 7 days);
        emit CrocEvents.TreasurySet(treasury_, treasuryStartTime_);
    }

    function transferAuthority(bytes calldata cmd) private {
        (, address auth) = abi.decode(cmd, (uint8, address));

        require(
            auth != address(0) && auth.code.length > 0 && ICrocMaster(auth).acceptsCrocAuthority(), "Invalid Authority"
        );

        emit CrocEvents.AuthorityTransfer(authority_);
        authority_ = auth;
    }

    /* @notice Used at upgrade time to verify that the contract is a valid Croc sidecar proxy and used
     *         in the correct slot. */
    function acceptCrocProxyRole(address, uint16 slot) public pure returns (bool) {
        return slot == CrocSlots.SAFE_MODE_PROXY_PATH;
    }
}
