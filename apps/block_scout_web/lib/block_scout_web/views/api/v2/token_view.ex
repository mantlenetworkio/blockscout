defmodule BlockScoutWeb.API.V2.TokenView do
  use BlockScoutWeb, :view
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  alias BlockScoutWeb.API.V2.Helper
  alias BlockScoutWeb.NFTHelper
  alias Ecto.Association.NotLoaded
  alias Explorer.Chain.{Address, BridgedToken}
  alias Explorer.Chain.ScaledUi.Reader, as: ScaledUiReader
  alias Explorer.Chain.Token.Instance

  def render("token.json", %{token: nil = token, contract_address_hash: contract_address_hash}) do
    %{
      "address_hash" => Address.checksum(contract_address_hash),
      "symbol" => nil,
      "name" => nil,
      "decimals" => nil,
      "type" => nil,
      "holders_count" => nil,
      "exchange_rate" => nil,
      "volume_24h" => nil,
      "total_supply" => nil,
      "icon_url" => nil,
      "circulating_market_cap" => nil,
      "reputation" => nil
    }
    |> maybe_append_bridged_info(token)
  end

  def render("token.json", %{token: nil}) do
    nil
  end

  def render("token.json", %{token: token} = assigns) do
    %{
      "address_hash" => Address.checksum(token.contract_address_hash),
      "symbol" => token.symbol,
      "name" => token.name,
      "decimals" => token.decimals,
      "type" => token.type,
      "holders_count" => prepare_holders_count(token.holder_count),
      "exchange_rate" => exchange_rate(token),
      "volume_24h" => token.volume_24h,
      "total_supply" => token.total_supply,
      "icon_url" => token.icon_url,
      "circulating_market_cap" => token.circulating_market_cap,
      "reputation" => token.reputation
    }
    |> maybe_append_extensions(token)
    |> maybe_append_scaled_ui(token, Map.get(assigns, :head_timestamp))
    |> maybe_append_bridged_info(token)
    |> chain_type_fields(%{address: token.contract_address, field_prefix: nil})
  end

  def render("token_holders.json", %{
        token_balances: token_balances,
        next_page_params: next_page_params
      }) do
    %{
      "items" => Enum.map(token_balances, &prepare_token_holder(&1)),
      "next_page_params" => next_page_params
    }
  end

  def render("token_instance.json", %{token_instance: token_instance, token: token}) do
    prepare_token_instance(token_instance, token)
  end

  def render("tokens.json", %{tokens: tokens, next_page_params: next_page_params}) do
    %{"items" => Enum.map(tokens, &render("token.json", %{token: &1})), "next_page_params" => next_page_params}
  end

  def render("scaled_ui_multiplier_updates.json", %{
        events: events,
        next_page_params: next_page_params,
        timeline_status: timeline_status
      }) do
    %{
      "items" => Enum.map(events, &prepare_scaled_ui_multiplier_update/1),
      "next_page_params" => next_page_params,
      "timeline_status" => timeline_status
    }
  end

  def render("token_instances.json", %{
        token_instances: token_instances,
        next_page_params: next_page_params,
        token: token
      }) do
    %{
      "items" => Enum.map(token_instances, &render("token_instance.json", %{token_instance: &1, token: token})),
      "next_page_params" => next_page_params
    }
  end

  def render("bridged_tokens.json", %{tokens: tokens, next_page_params: next_page_params}) do
    %{"items" => Enum.map(tokens, &render("bridged_token.json", %{token: &1})), "next_page_params" => next_page_params}
  end

  def render("bridged_token.json", %{token: {token, bridged_token}} = assigns) do
    "token.json"
    |> render(%{token: token, head_timestamp: Map.get(assigns, :head_timestamp)})
    |> Map.merge(%{
      foreign_address: Address.checksum(bridged_token.foreign_token_contract_address_hash),
      bridge_type: bridged_token.type,
      origin_chain_id: bridged_token.foreign_chain_id
    })
  end

  def exchange_rate(%{fiat_value: fiat_value}) when not is_nil(fiat_value), do: to_string(fiat_value)
  def exchange_rate(_), do: nil

  defp prepare_token_holder(token_balance) do
    %{
      "address" => Helper.address_with_info(nil, token_balance.address, token_balance.address_hash, false),
      "value" => token_balance.value,
      "token_id" => token_balance.token_id
    }
    |> maybe_put("scaled_value", token_balance.scaled_value)
  end

  defp prepare_scaled_ui_multiplier_update({event, status}) do
    %{
      "block_hash" => to_string(event.block_hash),
      "block_number" => event.block_number,
      "block_timestamp" => event.block.timestamp,
      "effective_at" => decimal_string(event.effective_at),
      "event_type" => event.event_type,
      "log_index" => event.log_index,
      "new_multiplier" => decimal_string(event.new_multiplier),
      "old_multiplier" => decimal_string(event.old_multiplier),
      "overwritten_effective_at" => decimal_string(event.overwritten_effective_at),
      "overwritten_multiplier" => decimal_string(event.overwritten_multiplier),
      "status" => status,
      "transaction_hash" => to_string(event.transaction_hash)
    }
  end

  @doc """
    Internal json rendering function
  """
  def prepare_token_instance(instance, token) do
    %{
      "id" => instance.token_id,
      "metadata" => instance.metadata,
      "owner" => token_instance_owner(instance.is_unique, instance),
      "token" => render("token.json", %{token: token}),
      "external_app_url" => NFTHelper.external_url(instance),
      "animation_url" => instance.metadata && NFTHelper.retrieve_image(instance.metadata["animation_url"]),
      "image_url" => instance.metadata && NFTHelper.get_media_src(instance.metadata, false),
      "is_unique" => instance.is_unique,
      "thumbnails" => instance.thumbnails,
      "media_type" => instance.media_type,
      "media_url" => Instance.get_media_url_from_metadata_for_nft_media_handler(instance.metadata)
    }
  end

  defp token_instance_owner(false, _instance), do: nil
  defp token_instance_owner(nil, _instance), do: nil

  defp token_instance_owner(_is_unique, %Instance{owner: %NotLoaded{}} = instance),
    do: Helper.address_with_info(nil, nil, instance.owner_address_hash, false)

  defp token_instance_owner(_is_unique, %Instance{owner: nil} = instance),
    do: Helper.address_with_info(nil, nil, instance.owner_address_hash, false)

  defp token_instance_owner(_is_unique, instance),
    do: instance.owner && Helper.address_with_info(nil, instance.owner, instance.owner.hash, false)

  defp prepare_holders_count(nil), do: nil
  defp prepare_holders_count(count) when count < 0, do: prepare_holders_count(0)
  defp prepare_holders_count(count), do: to_string(count)

  defp maybe_append_bridged_info(map, token) do
    if BridgedToken.enabled?() do
      (token && Map.put(map, "is_bridged", token.bridged || false)) || map
    else
      map
    end
  end

  defp maybe_append_extensions(map, %{extensions: extensions}) when is_list(extensions) and extensions != [],
    do: Map.put(map, "extensions", extensions)

  defp maybe_append_extensions(map, _token), do: map

  defp maybe_append_scaled_ui(map, %{scaled_ui_state: %NotLoaded{}}, _head_timestamp), do: map
  defp maybe_append_scaled_ui(map, _token, nil), do: map

  defp maybe_append_scaled_ui(
         map,
         %{scaled_ui_state: %{capability_block: capability_block} = state} = token,
         head_timestamp
       )
       when is_integer(capability_block) do
    {multiplier, pending_multiplier, pending_effective_at} = scaled_ui_multipliers(state, head_timestamp)

    Map.put(map, "scaled_ui", %{
      "capability_block" => capability_block,
      "multiplier" => multiplier,
      "pending_effective_at" => pending_effective_at,
      "pending_multiplier" => pending_multiplier,
      "scaled_total_supply" => ScaledUiReader.scaled_amount(token.total_supply, state, head_timestamp),
      "timeline_status" => state.timeline_status
    })
  end

  defp maybe_append_scaled_ui(map, _token, _head_timestamp), do: map

  defp scaled_ui_multipliers(state, head_timestamp) do
    case ScaledUiReader.current_multiplier(state, head_timestamp) do
      {:ok, multiplier} ->
        case ScaledUiReader.pending_schedule(state, head_timestamp) do
          {pending_multiplier, pending_effective_at} -> {multiplier, pending_multiplier, pending_effective_at}
          nil -> {multiplier, nil, nil}
        end

      :unknown ->
        {nil, nil, nil}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decimal_string(nil), do: nil
  defp decimal_string(value), do: Decimal.to_string(value, :normal)

  case @chain_type do
    :filecoin ->
      defp chain_type_fields(result, params) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        BlockScoutWeb.API.V2.FilecoinView.put_filecoin_robust_address(result, params)
      end

    :zilliqa ->
      defp chain_type_fields(result, params) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        BlockScoutWeb.API.V2.ZilliqaView.extend_token_json_response(result, params.address)
      end

    _ ->
      defp chain_type_fields(result, _params) do
        result
      end
  end
end
