import $ from 'jquery'
import {
  connectSelector,
  disconnectSelector,
  getCurrentAccountPromise,
  getContractABI,
  getMethodInputs,
  prepareMethodArgs
} from './common_helpers'
import { queryMethod, callMethod } from './interact'
import {
  walletEnabled,
  connectToWallet,
  disconnectWallet,
  web3ModalInit
} from './connect.js'
import '../../pages/address'
import { getParam } from '../../pages/layout.js'

let walletInit = false
const loadFunctions = (element, isCustomABI, from) => {
  const $element = $(element)
  const url = $element.data('url')
  const hash = $element.data('hash')
  const type = $element.data('type')
  const action = $element.data('action')

  const typeForId = type === 'proxy' ? 'proxy' : 'contract'

  $.get(
    url,
    { hash, type, action, is_custom_abi: isCustomABI, from },
    (response) => $element.html(response)
  )
    .done(function () {
      $(
        '.web3-connect-wrapper',
        $element.parents('.contract-handler-container')
      ).fadeIn()

      $(connectSelector, $(`#${action}-${typeForId}`)).length &&
        $(connectSelector, $(`#${action}-${typeForId}`)).on(
          'click',
          connectToWallet
        )

      $(disconnectSelector, $(`#${action}-${typeForId}`)).length &&
        $(disconnectSelector, $(`#${action}-${typeForId}`)).on(
          'click',
          disconnectWallet
        )

      if (!walletInit) {
        web3ModalInit(connectToWallet)
        walletInit = true
      }

      const selector = isCustomABI
        ? '[data-function-custom]'
        : '[data-function]'

      $(selector, $element).each((_, element) => {
        readWriteFunction(element)
      })

      $('.contract-exponentiation-btn', $element).on('click', (event) => {
        const $customPower = $(event.currentTarget).find('[name=custom_power]')
        let power
        if ($customPower.length > 0) {
          // @ts-ignore
          power = parseInt($customPower.val(), 10)
        } else {
          power = parseInt($(event.currentTarget).data('power'), 10)
        }
        // const $input = $(event.currentTarget)
        //   .parent()
        //   .parent()
        //   .parent()
        //   .find('[name=function_input]')
        const $input = $(event.currentTarget)
          .parents('.number-input-container')
          .find('[name=function_input]')

        if ($input.length) {
          const currentInputVal = parseInt($input.val(), 10) || 1
          const newInputVal = (currentInputVal * Math.pow(10, power)).toString()
          $input.val(newInputVal.toString())
        }
      })

      $('[name=custom_power]', $element).on('click', (event) => {
        $(event.currentTarget).parent().parent().toggleClass('show')
      })
    })
    .fail(function (response) {
      $element.html(response.statusText)
    })
}

const readWriteFunction = (element) => {
  const $element = $(element)
  const $form = $element.find('[data-function-form]')

  const $responseContainer = $element.find('[data-function-response]')

  $form.on('submit', (event) => {
    event.preventDefault()
    const action = $form.data('action')
    const $errorContainer = $form.parent().find('[input-parse-error-container]')

    $errorContainer.hide()

    const $functionInputs = $form.find('input[name=function_input]')
    const $functionName = $form.find('input[name=function_name]')
    const functionName = $functionName && $functionName.val()

    if (action === 'read') {
      const url = $form.data('url')

      const contractAbi = getContractABI($form)
      const inputs = getMethodInputs(contractAbi, functionName)
      const $methodId = $form.find('input[name=method_id]')
      let args
      try {
        args = prepareMethodArgs($functionInputs, inputs)
      } catch (exception) {
        $errorContainer.show()
        $errorContainer.text(exception)
        return
      }
      const isProxy = getParam('contract-tab') && getParam('contract-tab').includes('proxy')
      const type = isProxy ? 'proxy' : $('[data-smart-contract-functions]').data('type')
      const isCustomABI = $form.data('custom-abi')

      walletEnabled().then((isWalletEnabled) =>
        queryMethod(
          isWalletEnabled,
          url,
          $methodId,
          args,
          type,
          functionName,
          $responseContainer,
          isCustomABI
        )
      )
    } else if (action === 'write') {
      const explorerChainId = $form.data('chainId')
      walletEnabled().then((isWalletEnabled) =>
        callMethod(
          isWalletEnabled,
          $functionInputs,
          explorerChainId,
          $form,
          functionName,
          $element
        )
      )
    }
  })
}

const container = $('[data-smart-contract-functions]')

if (container.length) {
  container.each(function (_, ele) {
    getWalletAndLoadFunctions(false, $(ele))
  })
}

const customABIContainer = $('[data-smart-contract-functions-custom]')

if (customABIContainer.length) {
  customABIContainer.each(function (_, ele) {
    getWalletAndLoadFunctions(true, $(ele))
  })
}

function getWalletAndLoadFunctions(isCustomABI, container) {
  getCurrentAccountPromise(window.web3 && window.web3.currentProvider).then(
    (currentAccount) => {
      loadFunctions(container, isCustomABI, currentAccount)
    },
    () => {
      loadFunctions(container, isCustomABI, null)
    }
  )
}
