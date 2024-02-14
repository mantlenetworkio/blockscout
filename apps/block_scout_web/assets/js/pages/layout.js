import $ from 'jquery'
import { addChainToMM } from '../lib/add_chain_to_mm'
import * as analytics from '../lib/analytics'
import { commonPath } from '../lib/path_helper'

analytics.init()

const simpleEvents = {
  '.profile-button': 'Profile click',
  '.watchlist-button': 'Watch list click',
  '.address-tags-button': 'Address tags click',
  '.transaction-tags-button': 'Transaction tags click',
  '.api-keys-button': 'API keys click',
  '.custom-abi-button': 'Custom ABI click',
  '.public-tags-button': 'Public tags click',
  '.sign-out-button': 'Sign out click',
  '.sign-in-button': 'Sign in click',
  '.add-address-button': 'Add address to watch list click',
  '.add-address-tag-button': 'Add address tag click',
  '.add-transaction-tag-button': 'Add transaction tag click',
  '.add-api-key-button': 'Add API key click',
  '.add-custom-abi-button': 'Add custom ABI click',
  '.add-public-tag-button': 'Request to add public tag click'
}

if (analytics.mixpanelInitialized || analytics.amplitudeInitialized) {
  for (const elementClass in simpleEvents) {
    $(elementClass).click((_event) => {
      analytics.trackEvent(simpleEvents[elementClass])
    })
  }
}

// refetch token metadata
$('.btn-refetch-icon').on('click', (e) => {
  const id = e.currentTarget.dataset.id
  const address = e.currentTarget.dataset.address

  if (e.currentTarget.classList.contains('fetching')) {
    return
  }

  if (id && address) {
    e.currentTarget.classList.add('fetching')
    $.ajax({
      url: `/api/v1/asset/${address}/${id}`,
      success: (_data, _status, xhr) => {
        console.log(_data)
        location.reload()
      },
      error: (xhr) => {
        location.reload()
      }
    })
  } else {
    location.reload()
  };
})

export const getParam = (key) => {
  if (!key) return false
  const url = window.location
  const params = new URLSearchParams(url.search)
  if (params.has(key)) {
    return params.get(key)
  }
  return false
}

const addParam = (key, val) => {
  if (!key || !val) return
  const currUrl = new URL(location)
  currUrl.searchParams.set(key, val)
  history.pushState({}, '', currUrl)
}

$('#addressContractTab button.nav-link').on('click', (e) => {
  const target = $(e.currentTarget).data('target')
  const applyParam = target.slice(1, target.length)
  console.log({ target, applyParam })
  addParam('contract-tab', applyParam)
})

if ($('#addressContractTab').length && getParam('contract-tab')) {
  const currTabs = getParam('contract-tab')
  if ($(`#${currTabs}`).length) {
    $(`button[data-target='#${currTabs}']`).trigger('click')
  }
}

const handleWindowOnScroll = (e) => {
  if (e.currentTarget.scrollY > 100) {
    $('.scroll-top-btn').fadeIn()
  } else {
    $('.scroll-top-btn').fadeOut()
  }
}

$(window).on('scroll', handleWindowOnScroll)

$('.scroll-top-btn').on('click', () => {
  window.scrollTo({
    top: 0,
    behavior: 'smooth'
  })
})

$('.save-address-button').click((_event) => {
  const eventProperties = {
    address_hash: $('#watchlist_address_address_hash').val(),
    private_tag: $('#watchlist_address_name').val(),
    eth_incoming: $('#watchlist_address_watch_coin_input').prop('checked'),
    eth_outgoing: $('#watchlist_address_watch_coin_output').prop('checked'),
    erc_20_incoming: $('#watchlist_address_watch_erc_20_input').prop('checked'),
    erc_20_outgoing: $('#watchlist_address_watch_erc_20_output').prop(
      'checked'
    ),
    erc_721_1155_incoming: $('#watchlist_address_watch_erc_721_input').prop(
      'checked'
    ),
    erc_721_1155_outgoing: $('#watchlist_address_watch_erc_721_output').prop(
      'checked'
    ),
    email_notifications: $('#watchlist_address_notify_email').prop('checked')
  }
  const eventName = 'New address to watchlist completed'

  analytics.trackEvent(eventName, eventProperties)
})

$('.save-address-tag-button').click((_event) => {
  const eventName = 'Add address tag completed'
  const eventProperties = {
    address_hash: $('#tag_address_address_hash').val(),
    private_tag: $('#tag_address_name').val()
  }

  analytics.trackEvent(eventName, eventProperties)
})

$('.save-transaction-tag-button').click((_event) => {
  const eventName = 'Add transaction tag completed'
  const eventProperties = {
    address_hash: $('#tag_transaction_tx_hash').val(),
    private_tag: $('#tag_transaction_name').val()
  }

  analytics.trackEvent(eventName, eventProperties)
})

$('.save-api-key-button').click((_event) => {
  const eventName = 'Generate API key completed'
  const eventProperties = {
    application_name: $('#key_name').val()
  }

  analytics.trackEvent(eventName, eventProperties)
})

$('.save-custom-abi-button').click((_event) => {
  const eventName = 'Custom ABI completed'
  const eventProperties = {
    smart_contract_address: $('#custom_abi_address_hash').val(),
    project_name: $('#custom_abi_name').val(),
    custom_abi: $('#custom_abi_abi').val()
  }

  analytics.trackEvent(eventName, eventProperties)
})

$('.send-public-tag-request-button').click((_event) => {
  const eventName = 'Request a public tag completed'
  const eventProperties = {
    name: $('#public_tags_request_full_name').val(),
    email: $('#public_tags_request_email').val(),
    company_name: $('#public_tags_request_company').val(),
    company_website: $('#public_tags_request_website').val(),
    goal: $('#public_tags_request_is_owner_true').prop('checked')
      ? 'Add tags'
      : 'Incorrect public tag',
    public_tag: $('#public_tags_request_tags').val(),
    smart_contracts: $('*[id=public_tags_request_addresses]').map((_i, el) => {
      // @ts-ignore
      return el.value
    }).get(),
    reason: $('#public_tags_request_additional_comment').val()
  }

  analytics.trackEvent(eventName, eventProperties)
})

$(document).ready(() => {
  let timer
  const waitTime = 500
  const observer = new MutationObserver((mutations) => {
    // @ts-ignore
    if (!mutations[0] || mutations[0].target.hidden) {
      return
    }

    const $results = $('li[id^="autoComplete_result_"]')

    clearTimeout(timer)
    timer = setTimeout(() => {
      let eventName = 'Occurs searching according to substring at the nav bar'
      let eventProperties = {
        search:
          $('.main-search-autocomplete').val() ||
          $('.main-search-autocomplete-mobile').val()
      }

      analytics.trackEvent(eventName, eventProperties)

      eventName = 'Search list displays at the nav bar'
      // @ts-ignore
      eventProperties = {
        resultsNumber: $results.length,
        results: $results.map((_i, el) => {
          // @ts-ignore
          return el.children[1].innerText
        })
      }

      analytics.trackEvent(eventName, eventProperties)
    }, waitTime)

    $results.click((event) => {
      const eventName = 'Search item click at the nav bar'
      const eventProperties = {
        item: event.currentTarget.innerText
      }

      analytics.trackEvent(eventName, eventProperties)
    })
  })
  observer.observe($('#autoComplete_list_1')[0], {
    attributeFilter: ['hidden'],
    childList: true
  })
  observer.observe($('#autoComplete_list_2')[0], {
    attributeFilter: ['hidden']
  })
})

$(document).click(function (event) {
  const clickover = $(event.target)
  const _opened = $('.navbar-collapse').hasClass('show')
  // @ts-ignore
  if (_opened === true && $('.navbar').find(clickover).length < 1) {
    $('.navbar-toggler').click()
  }
})

const search = (value) => {
  const eventName = 'Occurs searching according to substring at the nav bar'
  const eventProperties = {
    search: value
  }

  analytics.trackEvent(eventName, eventProperties)

  if (value) {
    window.location.href = `${commonPath}/search?q=${value}`
  }
}

$(document)
  .on('keyup', function (event) {
    if (event.key === '/') {
      $('.main-search-autocomplete').trigger('focus')
    }
  })
  .on('click', '.js-btn-add-chain-to-mm', (event) => {
    const $btn = $(event.target)
    addChainToMM({ btn: $btn })
  })

$('.main-search-autocomplete').on('keyup', function (event) {
  if (event.key === 'Enter') {
    let selected = false
    $('li[id^="autoComplete_result_"]').each(function () {
      if ($(this).attr('aria-selected')) {
        selected = true
      }
    })
    if (!selected) {
      // @ts-ignore
      search(event.target.value)
    }
  }
})

$('#search-icon').on('click', function (event) {
  const value =
    $('.main-search-autocomplete').val() ||
    $('.main-search-autocomplete-mobile').val()
  search(value)
})
$('#search-btn').on('click', function (event) {
  const value =
    $('.main-search-autocomplete').val() ||
    $('.main-search-autocomplete-mobile').val()
  search(value)
})
if (window.innerWidth <= 1199) {
  if (
    document.getElementsByClassName('search-btn-cls') &&
    document.getElementsByClassName('search-btn-cls').length > 1
  ) {
    document
      .getElementsByClassName('search-btn-cls')[1]
      .addEventListener('click', function () {
        const els = document.getElementsByClassName('main-search-autocomplete')
        if (els && els.length > 1) {
          let value = els[1].value
          if (value) {
            search(value)
          }
        }
      })
  }
}

if (window.innerWidth <= 1199) {
  if (
    document.getElementsByClassName('search-icon-cls') &&
    document.getElementsByClassName('search-icon-cls').length > 1
  ) {
    document
      .getElementsByClassName('search-icon-cls')[1]
      .addEventListener('click', function () {
        const els = document.getElementsByClassName('main-search-autocomplete')
        if (els && els.length > 1) {
          let value = els[1].value
          if (value) {
            search(value)
          }
        }
      })
  }
}

$('.main-search-autocomplete').on('focus', function (_event) {
  $('#slash-icon').hide()
  //$('.search-control').addClass('focused-field')
})

$('.main-search-autocomplete').on('focusout', function (_event) {
  $('#slash-icon').show()
  //$('.search-control').removeClass('focused-field')
})
