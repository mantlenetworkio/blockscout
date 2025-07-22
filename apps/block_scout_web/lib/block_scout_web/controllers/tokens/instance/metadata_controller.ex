defmodule BlockScoutWeb.Tokens.Instance.MetadataController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.Tokens.Instance.Helper
  alias Explorer.Chain

  def index(conn, %{"token_id" => token_address_hash, "instance_id" => token_id_string}) do
    options = [necessity_by_association: %{[contract_address: :smart_contract] => :optional}]

    with {:ok, hash} <- Chain.string_to_address_hash(token_address_hash),
         {:ok, token} <- Chain.token_from_address_hash(hash, options),
         false <- Chain.erc_20_token?(token),
         {token_id, ""} <- Integer.parse(token_id_string),
         {:ok, token_instance} <-
           Chain.nft_instance_from_token_id_and_token_address(token_id, hash) do
      if token_instance.metadata do
        Helper.render(conn, token_instance, hash, token_id, token)
      else
        not_found(conn)
      end
    else
      _ ->
        not_found(conn)
    end
  end

  def index(conn, _) do
    not_found(conn)
  end

  def metadata(conn,%{"address_hash" => token_address_hash, "token_id" => token_id_str} = params) do
    force_update = Map.get(params, "force_update")
    options = [necessity_by_association: %{[contract_address: :smart_contract] => :optional}]
    with {:ok, hash} <- Chain.string_to_address_hash(token_address_hash),
        {:ok, token} <- Chain.token_from_address_hash(hash, options),
        false <- Chain.is_erc_20_token?(token),
        {token_id, ""} <- Integer.parse(token_id_str),
        {:ok, token_instance} <-
          Chain.erc721_or_erc1155_token_instance_from_token_id_and_token_address(token_id, hash) do

        case TokenInstance.Helper.fetch_instance(token_address_hash, token_id) do
          {:ok, %{metadata: metadata}} ->
            res = %{
              "token_id" => token_id_str,
              "token_contract_address_hash" => token_address_hash,
              "metadata" => metadata,
            }|> Jason.encode!()
            send_resp(conn, 200, res)
          _ ->
            res = %{
              "token_id" => token_id_str,
              "token_contract_address_hash" => token_address_hash,
            }
            |> Jason.encode!()
            send_resp(conn, 200, res)
        end

    else
    _ ->
      send_resp(conn, 404, Poison.encode!(@not_ok_resp))
    end
  end

end
