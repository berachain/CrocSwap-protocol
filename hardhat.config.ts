/**
 * @type import('hardhat/config').HardhatUserConfig
 */

require("hardhat-tracer");


import "hardhat-typechain";
import "@nomiclabs/hardhat-ethers";
import "hardhat-contract-sizer";
import "@nomicfoundation/hardhat-verify";
import "hardhat-storage-layout";
import "solidity-coverage";
import { config } from "dotenv";
require("hardhat-tracer");

config();

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          outputSelection: {
            "*": {
              "*": ["storageLayout"],
            },
          },
        },
      },
    ],
    overrides: {},
  },
  etherscan: {
    apiKey: {
      bartio: "bartio_testnet", // apiKey is not required, just set a placeholder
    },
    customChains: [
      {
        network: "bartio",
        chainId: 80084,
        urls: {
          apiURL: "https://api.routescan.io/v2/network/testnet/evm/80084/etherscan",
          browserURL: "https://bartio.beratrail.io"
        }
      }
    ]
  },
  networks: {
    local: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
      accounts: ["0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"]
    },
    ropsten: {
      url: "https://ropsten.infura.io/v3/cf3bc905d88d4f248c6be347adc8a1d8",
      chainId: 3,
      accounts: [
        "0x7c5e2cfbba7b00ba95e5ed7cd80566021da709442e147ad3e08f23f5044a3d5a",
      ],
    },
    rinkeby: {
      url: "https://rinkeby.infura.io/v3/cf3bc905d88d4f248c6be347adc8a1d8",
      chainId: 4,
      accounts: [
        "0x7c5e2cfbba7b00ba95e5ed7cd80566021da709442e147ad3e08f23f5044a3d5a",
      ],
    },
    kovan: {
      url: "https://kovan.infura.io/v3/cf3bc905d88d4f248c6be347adc8a1d8",
      chainId: 42,
      accounts: [
        "0x7c5e2cfbba7b00ba95e5ed7cd80566021da709442e147ad3e08f23f5044a3d5a",
      ],
    },
    goerli: {
      url: "https://goerli.infura.io/v3/cf3bc905d88d4f248c6be347adc8a1d8",
      chainId: 5,
      accounts: [
        "0x7c5e2cfbba7b00ba95e5ed7cd80566021da709442e147ad3e08f23f5044a3d5a",
      ],
    },
    mainnet: {
      url: "https://mainnet.infura.io/v3/360ea5fda45b4a22883de8522ebd639e",
      chainId: 1,
    },
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      chainId: 43113,
    },
    op: {
      url: "https://sepolia.optimism.io",
      chainId: 11155420,
      accounts: ["0xfffdbb37105441e14b0ee6330d855d8504ff39e705c3afa8f859ac9865f99306"],
    },
    artio: {
      url: "https://artio.rpc.berachain.com/",
      chainId: 80085,
      gasPrice: 10000000000,
      accounts: [
        (process.env.WALLET_KEY as string) ??
          "0x7c5e2cfbba7b00ba95e5ed7cd80566021da709442e147ad3e08f23f5044a3d5a",
      ],
    },
    devnet: {
      url: "https://devnet-eth-rpc.berachain-devnet.com/",
      chainId: 80086,
      gasPrice: 10000000000,
      accounts: [process.env.WALLET_KEY],
    },
    bartio: {
      url: "https://bartio.rpc.berachain.com",
      chainId: 80084,
      gasPrice: 10000000000,
      accounts: [process.env.WALLET_KEY],
    }
  },
};
