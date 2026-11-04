# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Market.Fetcher.TokenTest do
  use Explorer.DataCase

  import Mox

  alias Plug.Conn
  alias Explorer.Chain.Token
  alias Explorer.Market.Fetcher.Token, as: TokenFetcher

  @moduletag :capture_log

  setup :verify_on_exit!

  describe "handle_info(:fetch, state)" do
    setup do
      bypass = Bypass.open()

      # token icons are optional, so these tests serve no icons
      Bypass.stub(bypass, "GET", "/coins/markets", fn conn -> Conn.resp(conn, 200, "[]") end)

      source_configuration = Application.get_env(:explorer, Explorer.Market.Source)
      fetcher_configuration = Application.get_env(:explorer, Explorer.Market.Fetcher.Token)
      coin_gecko_configuration = Application.get_env(:explorer, Explorer.Market.Source.CoinGecko)

      Application.put_env(:explorer, Explorer.Market.Source, tokens_source: Explorer.Market.Source.CoinGecko)

      Application.put_env(:explorer, Explorer.Market.Fetcher.Token,
        enabled: true,
        interval: 0,
        refetch_interval: 10000,
        max_batch_size: 10
      )

      Application.put_env(:explorer, Explorer.Market.Source.CoinGecko,
        platform: "ethereum",
        currency: "usd",
        base_url: "http://localhost:#{bypass.port}"
      )

      Application.put_env(:tesla, :adapter, Tesla.Adapter.Mint)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.Market.Source, source_configuration)
        Application.put_env(:explorer, Explorer.Market.Fetcher.Token, fetcher_configuration)
        Application.put_env(:explorer, Explorer.Market.Source.CoinGecko, coin_gecko_configuration)
        Application.put_env(:tesla, :adapter, Explorer.Mock.TeslaAdapter)
      end)

      [_token_with_no_exchange_rate | tokens] =
        for _ <- 0..4 do
          insert(:token, fiat_value: nil)
        end

      {:ok, %{bypass: bypass, tokens: tokens}}
    end

    test "success fetch", %{bypass: bypass, tokens: tokens} do
      coins_list =
        tokens
        |> Enum.map(fn %{contract_address_hash: contract_address_hash} ->
          %{
            "id" => "#{contract_address_hash}_id",
            "symbol" => "#{contract_address_hash}_symbol",
            "name" => "#{contract_address_hash}_name",
            "platforms" => %{
              "some_other_chain" => "we do not want this to appear in the /simple/token_price/ request",
              "ethereum" => "#{contract_address_hash}"
            }
          }
        end)

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        assert conn.query_string == "include_platform=true"
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      token_exchange_rates =
        tokens
        |> Enum.reduce(%{}, fn %{contract_address_hash: contract_address_hash}, acc ->
          Map.put(acc, "#{contract_address_hash}_id", %{
            "usd" => 1..100 |> Enum.random() |> Decimal.new() |> Decimal.mult(Decimal.from_float(0.7))
          })
        end)

      joined_ids =
        tokens
        |> Enum.reverse()
        |> Enum.map_join(",", fn %{contract_address_hash: contract_address_hash} -> "#{contract_address_hash}_id" end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/simple/price",
        fn conn ->
          assert conn.query_string ==
                   "vs_currencies=usd&include_market_cap=true&include_24hr_vol=true&ids=#{joined_ids}"

          Conn.resp(conn, 200, Jason.encode!(token_exchange_rates))
        end
      )

      GenServer.start_link(TokenFetcher, [])

      :timer.sleep(100)

      Repo.all(Token)
      |> Enum.each(fn %{contract_address_hash: contract_address_hash, fiat_value: fiat_value} ->
        assert token_exchange_rates[contract_address_hash]["usd"] == fiat_value
      end)
    end

    test "empty body in /coins/list response", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/coins/list", fn conn ->
        assert conn.query_string == "include_platform=true"
        Conn.resp(conn, 200, "[]")
      end)

      GenServer.start_link(TokenFetcher, [])

      :timer.sleep(100)

      Repo.all(Token)
      |> Enum.each(fn %{fiat_value: fiat_value} -> assert is_nil(fiat_value) end)
    end

    test "empty body in fetch response", %{bypass: bypass, tokens: tokens} do
      coins_list =
        tokens
        |> Enum.map(fn %{contract_address_hash: contract_address_hash} ->
          %{
            "id" => "#{contract_address_hash}_id",
            "symbol" => "#{contract_address_hash}_symbol",
            "name" => "#{contract_address_hash}_name",
            "platforms" => %{
              "some_other_chain" => "we do not want this to appear in the /simple/token_price/ request",
              "ethereum" => "#{contract_address_hash}"
            }
          }
        end)

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        assert conn.query_string == "include_platform=true"
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      joined_ids =
        tokens
        |> Enum.reverse()
        |> Enum.map_join(",", fn %{contract_address_hash: contract_address_hash} -> "#{contract_address_hash}_id" end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/simple/price",
        fn conn ->
          assert conn.query_string ==
                   "vs_currencies=usd&include_market_cap=true&include_24hr_vol=true&ids=#{joined_ids}"

          Conn.resp(conn, 200, "{}")
        end
      )

      GenServer.start_link(TokenFetcher, [])

      :timer.sleep(100)

      Repo.all(Token)
      |> Enum.each(fn %{fiat_value: fiat_value} -> assert is_nil(fiat_value) end)
    end

    test "error in /coins/list response", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/coins/list", fn conn ->
        assert conn.query_string == "include_platform=true"
        Conn.resp(conn, 429, "Too many requests")
      end)

      GenServer.start_link(TokenFetcher, [])

      :timer.sleep(100)

      Repo.all(Token)
      |> Enum.each(fn %{fiat_value: fiat_value} -> assert is_nil(fiat_value) end)
    end

    test "error in fetch response", %{bypass: bypass, tokens: tokens} do
      coins_list =
        tokens
        |> Enum.map(fn %{contract_address_hash: contract_address_hash} ->
          %{
            "id" => "#{contract_address_hash}_id",
            "symbol" => "#{contract_address_hash}_symbol",
            "name" => "#{contract_address_hash}_name",
            "platforms" => %{
              "some_other_chain" => "we do not want this to appear in the /simple/token_price/ request",
              "ethereum" => "#{contract_address_hash}"
            }
          }
        end)

      Bypass.expect(bypass, "GET", "/coins/list", fn conn ->
        assert conn.query_string == "include_platform=true"
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      joined_ids =
        tokens
        |> Enum.reverse()
        |> Enum.map_join(",", fn %{contract_address_hash: contract_address_hash} -> "#{contract_address_hash}_id" end)

      Bypass.expect(
        bypass,
        "GET",
        "/simple/price",
        fn conn ->
          assert conn.query_string ==
                   "vs_currencies=usd&include_market_cap=true&include_24hr_vol=true&ids=#{joined_ids}"

          Conn.resp(conn, 429, "Too many requests")
        end
      )

      GenServer.start_link(TokenFetcher, [])

      :timer.sleep(100)

      Repo.all(Token)
      |> Enum.each(fn %{fiat_value: fiat_value} -> assert is_nil(fiat_value) end)
    end

    test "imports token icons without replacing existing ones", %{bypass: bypass} do
      token_without_icon = insert(:token, icon_url: nil)
      token_with_icon = insert(:token, icon_url: "https://example.com/existing.png")
      tokens = [token_without_icon, token_with_icon]

      coins_list =
        Enum.map(tokens, fn %{contract_address_hash: hash} ->
          %{"id" => "#{hash}_id", "symbol" => "s", "name" => "n", "platforms" => %{"ethereum" => "#{hash}"}}
        end)

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      Bypass.expect_once(bypass, "GET", "/simple/price", fn conn ->
        prices =
          Map.new(
            tokens,
            &{"#{&1.contract_address_hash}_id", %{"usd" => 1.5, "usd_market_cap" => 100, "usd_24h_vol" => 10}}
          )

        Conn.resp(conn, 200, Jason.encode!(prices))
      end)

      Bypass.expect_once(bypass, "GET", "/coins/markets", fn conn ->
        coins =
          Enum.map(tokens, fn %{contract_address_hash: hash} ->
            %{"id" => "#{hash}_id", "image" => "https://coin-images.coingecko.com/coins/images/1/large/#{hash}.png"}
          end)

        Conn.resp(conn, 200, Jason.encode!(coins))
      end)

      GenServer.start_link(TokenFetcher, [])

      assert wait_for_icon(token_without_icon) ==
               "https://coin-images.coingecko.com/coins/images/1/small/#{token_without_icon.contract_address_hash}.png"

      assert Repo.get_by(Token, contract_address_hash: token_with_icon.contract_address_hash).icon_url ==
               "https://example.com/existing.png"
    end

    test "fills a missing icon even when the market data did not change", %{bypass: bypass} do
      # the import pre-filter compares stored prices, which only load while the token fetcher is enabled
      previous_fetcher_enabled = :persistent_term.get(:market_token_fetcher_enabled, false)
      :persistent_term.put(:market_token_fetcher_enabled, true)
      on_exit(fn -> :persistent_term.put(:market_token_fetcher_enabled, previous_fetcher_enabled) end)

      token =
        insert(:token,
          name: "n",
          symbol: "s",
          fiat_value: Decimal.new("1.5"),
          circulating_market_cap: Decimal.new("100"),
          volume_24h: Decimal.new("10"),
          icon_url: nil
        )

      id = "#{token.contract_address_hash}_id"

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        coins_list = [
          %{
            "id" => id,
            "symbol" => "s",
            "name" => "n",
            "platforms" => %{"ethereum" => "#{token.contract_address_hash}"}
          }
        ]

        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      Bypass.expect_once(bypass, "GET", "/simple/price", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(%{id => %{"usd" => 1.5, "usd_market_cap" => 100, "usd_24h_vol" => 10}}))
      end)

      Bypass.expect_once(bypass, "GET", "/coins/markets", fn conn ->
        Conn.resp(conn, 200, Jason.encode!([%{"id" => id, "image" => "https://example.com/large/icon.png"}]))
      end)

      GenServer.start_link(TokenFetcher, [])

      assert wait_for_icon(token) == "https://example.com/small/icon.png"
    end
  end

  defp wait_for_icon(%Token{contract_address_hash: hash}) do
    wait_for_results(fn ->
      Repo.one!(
        from(t in Token, where: t.contract_address_hash == ^hash and not is_nil(t.icon_url), select: t.icon_url)
      )
    end)
  end

  describe "stale market data cleanup" do
    # We test the full cycle through handle_info since nullify_stale_market_data is private.

    setup do
      bypass = Bypass.open()

      # token icons are optional, so these tests serve no icons
      Bypass.stub(bypass, "GET", "/coins/markets", fn conn -> Conn.resp(conn, 200, "[]") end)

      source_configuration = Application.get_env(:explorer, Explorer.Market.Source)
      fetcher_configuration = Application.get_env(:explorer, Explorer.Market.Fetcher.Token)
      coin_gecko_configuration = Application.get_env(:explorer, Explorer.Market.Source.CoinGecko)

      Application.put_env(
        :explorer,
        Explorer.Market.Source,
        Keyword.merge(source_configuration || [], tokens_source: Explorer.Market.Source.CoinGecko)
      )

      Application.put_env(
        :explorer,
        Explorer.Market.Fetcher.Token,
        Keyword.merge(fetcher_configuration || [],
          enabled: true,
          interval: 0,
          refetch_interval: 10_000,
          max_batch_size: 100
        )
      )

      Application.put_env(
        :explorer,
        Explorer.Market.Source.CoinGecko,
        Keyword.merge(coin_gecko_configuration || [],
          platform: "ethereum",
          currency: "usd",
          base_url: "http://localhost:#{bypass.port}"
        )
      )

      Application.put_env(:tesla, :adapter, Tesla.Adapter.Mint)

      previous_fetcher_enabled = :persistent_term.get(:market_token_fetcher_enabled, false)
      :persistent_term.put(:market_token_fetcher_enabled, true)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.Market.Source, source_configuration)
        Application.put_env(:explorer, Explorer.Market.Fetcher.Token, fetcher_configuration)
        Application.put_env(:explorer, Explorer.Market.Source.CoinGecko, coin_gecko_configuration)
        Application.put_env(:tesla, :adapter, Explorer.Mock.TeslaAdapter)
        :persistent_term.put(:market_token_fetcher_enabled, previous_fetcher_enabled)
      end)

      {:ok, %{bypass: bypass}}
    end

    test "nullifies market data for tokens not returned by source", %{bypass: bypass} do
      # Token that source WILL return
      token_returned =
        insert(:token,
          fiat_value: Decimal.new("5.0"),
          circulating_market_cap: Decimal.new("1000"),
          volume_24h: Decimal.new("500"),
          circulating_supply: Decimal.new("2000")
        )

      # Token that source will NOT return — should be nullified across all market fields
      token_stale =
        insert(:token,
          fiat_value: Decimal.new("3.0"),
          circulating_market_cap: Decimal.new("800"),
          volume_24h: Decimal.new("200"),
          circulating_supply: Decimal.new("1500")
        )

      # Token with nil fiat_value — WHERE clause should leave it alone even if not in seen set
      token_already_nil =
        insert(:token,
          fiat_value: nil,
          circulating_market_cap: nil,
          volume_24h: Decimal.new("999"),
          circulating_supply: Decimal.new("3000")
        )

      coins_list = [
        %{
          "id" => "returned_token",
          "symbol" => "RT",
          "name" => "Returned Token",
          "platforms" => %{"ethereum" => "#{token_returned.contract_address_hash}"}
        }
      ]

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      token_exchange_rates = %{
        "returned_token" => %{
          "usd" => 5.0,
          "usd_market_cap" => 1000.0,
          "usd_24h_vol" => 500.0
        }
      }

      Bypass.expect_once(bypass, "GET", "/simple/price", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(token_exchange_rates))
      end)

      GenServer.start_link(TokenFetcher, [])
      :timer.sleep(200)

      # Returned token keeps market data
      returned = Repo.get_by(Token, contract_address_hash: token_returned.contract_address_hash)
      assert returned.fiat_value
      assert returned.circulating_market_cap

      # Stale token has all market data fields nullified
      stale = Repo.get_by(Token, contract_address_hash: token_stale.contract_address_hash)
      assert is_nil(stale.fiat_value)
      assert is_nil(stale.circulating_market_cap)
      assert is_nil(stale.volume_24h)
      assert is_nil(stale.circulating_supply)

      # Token with nil fiat_value is skipped by the WHERE clause — other fields untouched
      skipped = Repo.get_by(Token, contract_address_hash: token_already_nil.contract_address_hash)
      assert Decimal.equal?(skipped.volume_24h, Decimal.new("999"))
      assert Decimal.equal?(skipped.circulating_supply, Decimal.new("3000"))
    end

    test "does not nullify when source errors out (empty coin list)", %{bypass: bypass} do
      # Empty /coins/list makes CoinGecko return {:error, "Tokens not found..."}, exercising
      # the error branch in handle_info — nullify is never called.
      token_with_data = insert(:token, fiat_value: Decimal.new("5.0"), circulating_market_cap: Decimal.new("1000"))

      Bypass.expect(bypass, "GET", "/coins/list", fn conn ->
        Conn.resp(conn, 200, "[]")
      end)

      GenServer.start_link(TokenFetcher, [])
      :timer.sleep(200)

      token = Repo.get_by(Token, contract_address_hash: token_with_data.contract_address_hash)
      assert token.fiat_value
    end

    test "skips nullification when all returned tokens are filtered out (empty seen set)", %{bypass: bypass} do
      # Source returns a token, but with $0 — zero_or_nil? filter drops it.
      # seen_token_hashes ends up empty → `!Enum.empty?` guard prevents any DB writes.
      token_existing = insert(:token, fiat_value: Decimal.new("5.0"), circulating_market_cap: Decimal.new("1000"))

      filtered_out_address = "0x00000000000000000000000000000000000000aa"

      coins_list = [
        %{
          "id" => "zero_token",
          "symbol" => "ZT",
          "name" => "Zero Token",
          "platforms" => %{"ethereum" => filtered_out_address}
        }
      ]

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      Bypass.expect_once(bypass, "GET", "/simple/price", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(%{"zero_token" => %{"usd" => 0, "usd_market_cap" => 0, "usd_24h_vol" => 0}}))
      end)

      GenServer.start_link(TokenFetcher, [])
      :timer.sleep(200)

      # Pre-existing token was NOT in the (empty) seen set, yet still retains data because
      # the guard short-circuits before the UPDATE runs.
      token = Repo.get_by(Token, contract_address_hash: token_existing.contract_address_hash)
      assert Decimal.equal?(token.fiat_value, Decimal.new("5.0"))
      assert Decimal.equal?(token.circulating_market_cap, Decimal.new("1000"))
    end

    test "tokens with $0 fiat_value are filtered out and their market data is nullified", %{bypass: bypass} do
      # Token that source returns with $0 price — filtered out, not added to seen set
      token_zero_price =
        insert(:token,
          fiat_value: Decimal.new("2.0"),
          circulating_market_cap: Decimal.new("500"),
          volume_24h: Decimal.new("50"),
          circulating_supply: Decimal.new("123")
        )

      # A second token with a real price — goes into seen set, triggering nullification of the $0 token
      token_real_price = insert(:token, fiat_value: Decimal.new("1.0"))

      coins_list = [
        %{
          "id" => "zero_price_token",
          "symbol" => "ZP",
          "name" => "Zero Price Token",
          "platforms" => %{"ethereum" => "#{token_zero_price.contract_address_hash}"}
        },
        %{
          "id" => "real_price_token",
          "symbol" => "RP",
          "name" => "Real Price Token",
          "platforms" => %{"ethereum" => "#{token_real_price.contract_address_hash}"}
        }
      ]

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      token_exchange_rates = %{
        "zero_price_token" => %{
          "usd" => 0,
          "usd_market_cap" => 0,
          "usd_24h_vol" => 0
        },
        "real_price_token" => %{
          "usd" => 10.0,
          "usd_market_cap" => 5000.0,
          "usd_24h_vol" => 100.0
        }
      }

      Bypass.expect_once(bypass, "GET", "/simple/price", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(token_exchange_rates))
      end)

      GenServer.start_link(TokenFetcher, [])
      :timer.sleep(200)

      # $0-price token is not in seen set → gets nullified across all market fields
      token = Repo.get_by(Token, contract_address_hash: token_zero_price.contract_address_hash)
      assert is_nil(token.fiat_value)
      assert is_nil(token.circulating_market_cap)
      assert is_nil(token.volume_24h)
      assert is_nil(token.circulating_supply)

      # Real-price token is in seen set → retains its data
      real = Repo.get_by(Token, contract_address_hash: token_real_price.contract_address_hash)
      assert real.fiat_value
    end

    test "keeps a contract that several coins list, priced or not", %{bypass: bypass} do
      listed = insert(:token, fiat_value: Decimal.new("5"), circulating_market_cap: Decimal.new("50"))
      other = insert(:token, fiat_value: Decimal.new("1"), circulating_market_cap: Decimal.new("10"))

      # `/coins/list` order matters: deduping before the price filter would keep the zero-priced or
      # the unpriced coin for `listed`, and not deduping would put both priced coins into one upsert
      aliases = [
        {"listed-zero", listed},
        {"listed", listed},
        {"listed-again", listed},
        {"listed-unpriced", listed},
        {"other", other}
      ]

      coins_list =
        for {id, token} <- aliases do
          %{"id" => id, "symbol" => id, "name" => id, "platforms" => %{"ethereum" => "#{token.contract_address_hash}"}}
        end

      Bypass.expect_once(bypass, "GET", "/coins/list", fn conn ->
        Conn.resp(conn, 200, Jason.encode!(coins_list))
      end)

      Bypass.expect_once(bypass, "GET", "/simple/price", fn conn ->
        price = %{"usd" => 2, "usd_market_cap" => 20, "usd_24h_vol" => 200}
        zero = %{"usd" => 0, "usd_market_cap" => 0, "usd_24h_vol" => 0}
        prices = %{"listed-zero" => zero, "listed" => price, "listed-again" => price, "other" => price}
        Conn.resp(conn, 200, Jason.encode!(prices))
      end)

      GenServer.start_link(TokenFetcher, [])

      wait_for_results(fn ->
        query = from(t in Token, where: t.contract_address_hash == ^other.contract_address_hash)
        Repo.one!(from(t in query, where: t.fiat_value == ^Decimal.new(2)))
      end)

      listed_fiat_value = Repo.get_by(Token, contract_address_hash: listed.contract_address_hash).fiat_value
      assert listed_fiat_value && Decimal.eq?(listed_fiat_value, 2)
    end
  end
end
