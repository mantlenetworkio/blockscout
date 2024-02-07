import Web3 from 'web3'
import { EthereumClient, w3mConnectors, w3mProvider } from '@web3modal/ethereum'
import { Web3Modal } from '@web3modal/html'
import { configureChains, createConfig } from '@wagmi/core'
import { mantle, mantleTestnet } from '@wagmi/core/chains'
import {
  compareChainIDs,
  formatError,
  showConnectElements,
  showConnectedToElements,
  mantleQa,
  mantleSepolia
} from './common_helpers'
import { openWarningModal } from '../modals'

// @ts-ignore
const instanceChainIdStr = document.getElementById('js-chain-id').value
const instanceChainId = parseInt(instanceChainIdStr, 10)
const walletConnectOptions = { rpc: {}, chainId: instanceChainId }
// @ts-ignore
const jsonRPC = document.getElementById('js-json-rpc').value
walletConnectOptions.rpc[instanceChainId] = jsonRPC

// Chosen wallet provider given by the dialog window
let provider

// Web3modal instance
let web3Modal

/**
 * Setup the orchestra
 */
export async function web3ModalInit (connectToWallet, ...args) {
  return new Promise((resolve) => {
    const projectId = '0f46802d607f6eddd6bc1a57428357f0'
    let chains = []
    if (instanceChainId === 1705003) {
      chains = [mantleQa]
    } else if (instanceChainId === 5001) {
      chains = [mantleTestnet]
    } else if (instanceChainId === 5000) {
      chains = [mantle]
    } else if (instanceChainId === 5003) {
      chains = [mantleSepolia]
    }

    const { publicClient } = configureChains(chains, [w3mProvider({ projectId })])
    const wagmiConfig = createConfig({
      autoConnect: true,
      connectors: w3mConnectors({ projectId, chains }),
      publicClient
    })
    const ethereumClient = new EthereumClient(wagmiConfig, chains)
    web3Modal = new Web3Modal({
      projectId,
      defaultChain: {
        id: chains[0].id,
        name: chains[0].name
      }
    }, ethereumClient)

    window.ec = ethereumClient

    ethereumClient.watchAccount(async (account) => {
      window.connector = account.connector
      if (account.isConnected) {
        provider = await account.connector.getProvider()
        window.web3 = new Web3(provider)
        connectToWalletAfterConnected()
      } else {
        disconnectWallet()
      }
    })
  })
}

export const walletEnabled = () => {
  return new Promise((resolve) => {
    if (
      window.web3 &&
      window.web3.currentProvider &&
      window.web3.currentProvider.isWalletConnect
    ) {
      resolve(true)
    } else {
      if (window.ethereum) {
        window.web3 = new Web3(window.ethereum)
        window.ethereum._metamask
          .isUnlocked()
          .then((isUnlocked) => {
            if (isUnlocked && window.ethereum.isNiftyWallet) {
              // Nifty Wallet
              window.web3 = new Web3(window.web3.currentProvider)
              resolve(true)
            } else if (isUnlocked === false && window.ethereum.isNiftyWallet) {
              // Nifty Wallet
              window.ethereum.enable()
              resolve(false)
            } else {
              if (window.ethereum.isNiftyWallet) {
                window.ethereum.enable()
                window.web3 = new Web3(window.web3.currentProvider)
                resolve(true)
              } else {
                return window.ethereum
                  .request({ method: 'eth_requestAccounts' })
                  .then((_res) => {
                    window.web3 = new Web3(window.web3.currentProvider)
                    resolve(true)
                  })
                  .catch((_error) => {
                    resolve(false)
                  })
              }
            }
          })
          .catch((_error) => {
            resolve(false)
          })
      } else if (window.web3) {
        window.web3 = new Web3(window.web3.currentProvider)
        resolve(true)
      } else {
        resolve(false)
      }
    }
  })
}

export async function disconnect() {
  if (window.ec && window.ec.disconnect) {
    await window.ec.disconnect()
  }

  provider = null

  window.web3 = null

  // If the cached provider is not cleared,
  // WalletConnect will default to the existing session
  // and does not allow to re-scan the QR code with a new wallet.
  // Depending on your use case you may want or want not his behavir.
  // await web3Modal.clearCachedProvider()
}

/**
 * Disconnect wallet button pressed.
 */
export async function disconnectWallet() {
  await disconnect()

  showConnectElements()
}

export const connectToProvider = () => {
  return new Promise((resolve, reject) => {
    try {
      web3Modal.connect().then((connectedProvider) => {
        provider = connectedProvider
        window.web3 = new Web3(provider)
        resolve(provider)
      })
    } catch (e) {
      reject(e)
    }
  })
}

export const connectToWallet = async () => {
  web3Modal.openModal()
}

export const connectToWalletAfterConnected = async () => {
  // Subscribe to accounts change
  // provider.on('accountsChanged', async (accs) => {
  //   const newAccount = accs && accs.length > 0 ? accs[0].toLowerCase() : null

  //   if (!newAccount) {
  //     await disconnectWallet()
  //   }

  //   fetchAccountData(showConnectedToElements, [])
  // })

  // // Subscribe to chainId change
  // provider.on('chainChanged', (chainId) => {
  //   compareChainIDs(instanceChainId, chainId)
  //     .then(() => fetchAccountData(showConnectedToElements, []))
  //     .catch((error) => {
  //       openWarningModal('Unauthorized', formatError(error))
  //     })
  // })

  // provider.on('disconnect', async () => {
  //   await disconnectWallet()
  // })

  await fetchAccountData(showConnectedToElements, [])
}

export async function fetchAccountData(setAccount, args) {
  // Get a Web3 instance for the wallet
  if (provider) {
    window.web3 = new Web3(provider)
  }

  // Get list of accounts of the connected wallet
  const accounts = window.web3 && (await window.web3.eth.getAccounts())

  // MetaMask does not give you all accounts, only the selected account
  if (accounts && accounts.length > 0) {
    const selectedAccount = accounts[0]

    setAccount(selectedAccount, ...args)
  }
}
