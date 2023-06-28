/**
 * Use this file to configure your truffle project. It's seeded with some
 * common settings for different networks and features like migrations,
 * compilation and testing. Uncomment the ones you need or modify
 * them to suit your project as necessary.
 *
 * More information about configuration can be found at:
 *
 * trufflesuite.com/docs/advanced/configuration
 *
 * To deploy via Infura you'll need a wallet provider (like @truffle/hdwallet-provider)
 * to sign your transactions before they're sent to a remote public node. Infura accounts
 * are available for free at: infura.io/register.
 *
 * You'll also need a mnemonic - the twelve word phrase the wallet uses to generate
 * public/private key pairs. If you're publishing your code to GitHub make sure you load this
 * phrase from a file you've .gitignored so it doesn't accidentally become public.
 *
 */

const HDWalletProvider = require('@truffle/hdwallet-provider');
const fs = require('fs');
var jsonfile = require('jsonfile');
var api_keys = jsonfile.readFileSync('./.api_keys');

module.exports = {
  /**
   * Networks define how you connect to your ethereum client and let you set the
   * defaults web3 uses to send transactions. If you don't specify one truffle
   * will spin up a development blockchain for you on port 9545 when you
   * run `develop` or `test`. You can ask a truffle command to use a specific
   * network from the command line, e.g
   *
   * $ truffle test --network <network-name>
   */

  networks: {
    // Useful for testing. The `development` name is special - truffle uses it by default
    // if it's defined here and no other network is specified at the command line.
    // You should run a client (like ganache-cli, geth or parity) in a separate terminal
    // tab if you use this network and you must also set the `host`, `port` and `network_id`
    // options below to some value.
    //
    mainnet: {
      // provider: () => new HDWalletProvider(mnemonic, `https://mainnet.infura.io/v3/<insert>`),
      provider: () => new HDWalletProvider(api_keys.mnemonic, api_keys.provider_mainnet),
      network_id: 1, 
      gas: 6721975,
      gasPrice: 25000000000
    },
    mainnetArb: {
      provider: () => new HDWalletProvider(api_keys.mnemonic, api_keys.provider_arbitrum),
      network_id: 42161,
      gasLimit: 6721975,
      gasPrice: 500000000
    },
    mainnetZksync: {
      provider: () => new HDWalletProvider(api_keys.mnemonic, api_keys.provider_zksync),
      network_id: 324,
      gasLimit: 6721975,
      gasPrice: 500000000
    },
    mainnetPoly: {
      provider: () => new HDWalletProvider(api_keys.mnemonic, api_keys.provider_polygon_llama),
      network_id: 137,
      // gasLimit: 6721975,
      gasPrice: 200000000000
    },
    mainnetZkevm: {
      provider: () => new HDWalletProvider(api_keys.mnemonic, api_keys.provider_zkevm),
      network_id: 1101,
      // gasLimit: 6721975,
      gasPrice: 2000000000,
      verify: {
        apiUrl: 'https://api-zkevm.polygonscan.com/api',
        apiKey: api_keys.zkevm_polyscan,
        explorerUrl: 'https://zkevm.polygonscan.com/address',
      }
    },
    mainnetOp: {
      provider: () => new HDWalletProvider(api_keys.mnemonic, api_keys.provider_optimism),
      network_id: 1, 
      gas: 6721975,
      gasPrice: 500000000
    },
    debugArb: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "42161",
      gas: 6721975,
      gasPrice: 500000000
    },
    debugZksync: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "324",
      gas: 6721975,
      gasPrice: 500000000
    },
    debugZkevm: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "1101",
      gas: 6721975,
      gasPrice: 500000000
    },
    debugPoly: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "137",
      gas: 6721975,
      gasPrice: 500000000
    },
    debug: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "1",
      gas: 6721975,
      gasPrice: 500000000
    },
  },

  // Set default mocha options here, use special reporters etc.
  mocha: {
    enableTimeouts: false,
    timeout: 100000000
  },

  // Configure your compilers
  compilers: {
    solc: {
       version: "0.8.10",    // Fetch exact version from solc-bin (default: truffle's version)
      // docker: true,        // Use "0.5.1" you've installed locally with docker (default: false)
       settings: {          // See the solidity docs for advice about optimization and evmVersion
         optimizer: {
           enabled: true,
           runs: 200
         }
      //  evmVersion: "byzantium"
      }
    }
  },
  plugins: [
    'truffle-plugin-verify'
  ],
  api_keys: {
    etherscan: api_keys.etherscan,
    arbiscan: api_keys.arbiscan,
    polygonscan: api_keys.polyscan
  }
};
