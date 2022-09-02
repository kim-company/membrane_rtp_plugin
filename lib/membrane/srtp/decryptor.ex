if Code.ensure_loaded?(ExLibSRTP) do
  defmodule Membrane.SRTP.Decryptor do
    @moduledoc """
    Converts SRTP packets to plain RTP.

    Decryptor expects that buffers passed to `handle_process/4` have already parsed headers
    in the metadata field as they contain information about header length. The header
    length is needed to avoid parsing the header twice in case of any elements preceding
    the decryptor needed the information to e.g. drop the packet before reaching the decryptor.
    `ExLibSRTP` expects a valid SRTP packet containing the header, after decryption, the
    payload binary again includes the header. The header's length simply allows stripping
    the header without any additional parsing.

    Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
    """
    use Membrane.Filter

    require Membrane.Logger

    alias Membrane.Buffer
    alias Membrane.RTP.Utils
    alias Membrane.SRTP

    def_input_pad :input, caps: :any, demand_mode: :auto
    def_output_pad :output, caps: :any, demand_mode: :auto

    def_options policies: [
                  spec: [ExLibSRTP.Policy.t()],
                  description: """
                  List of SRTP policies to use for decrypting packets.
                  See `t:ExLibSRTP.Policy.t/0` for details.
                  """
                ]

    @impl true
    def handle_init(%__MODULE__{policies: policies}) do
      state = %{
        policies: policies,
        srtp: nil
      }

      {:ok, state}
    end

    @impl true
    def handle_stopped_to_prepared(_ctx, state) do
      srtp = ExLibSRTP.new()

      state.policies
      |> Bunch.listify()
      |> Enum.each(&ExLibSRTP.add_stream(srtp, &1))

      {:ok, %{state | srtp: srtp}}
    end

    @impl true
    def handle_prepared_to_stopped(_ctx, state) do
      {:ok, %{state | srtp: nil, policies: []}}
    end

    @impl true
    def handle_event(_pad, %SRTP.KeyingMaterialEvent{} = event, _ctx, %{policies: []} = state) do
      {:ok, crypto_profile} =
        ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(
          event.protection_profile
        )

      policy = %ExLibSRTP.Policy{
        ssrc: :any_inbound,
        key: event.remote_keying_material,
        rtp: crypto_profile,
        rtcp: crypto_profile
      }

      :ok = ExLibSRTP.add_stream(state.srtp, policy)
      {:ok, Map.put(state, :policies, [policy])}
    end

    @impl true
    def handle_event(_pad, %SRTP.KeyingMaterialEvent{}, _ctx, state) do
      Membrane.Logger.warn("Got unexpected SRTP.KeyingMaterialEvent. Ignoring.")
      {:ok, state}
    end

    @impl true
    def handle_event(pad, other, ctx, state), do: super(pad, other, ctx, state)

    @impl true
    def handle_process(:input, buffer, _ctx, state) do
      %Buffer{
        payload: payload,
        metadata: %{
          rtp: %{
            has_padding?: has_padding?,
            total_header_size: total_header_size
          }
        }
      } = buffer

      state.srtp
      |> ExLibSRTP.unprotect(payload)
      |> case do
        {:ok, payload} ->
          # decrypted payload contains the header that we can simply strip without any parsing as we know its length
          <<_header::binary-size(total_header_size), payload::binary>> = payload

          {:ok, {payload, _size}} = Utils.strip_padding(payload, has_padding?)

          {{:ok, buffer: {:output, %Buffer{buffer | payload: payload}}}, state}

        {:error, reason} ->
          Membrane.Logger.debug("""
          Couldn't unprotect srtp packet:
          #{inspect(payload, limit: :infinity)}
          Reason: #{inspect(reason)}. Ignoring packet.
          """)

          {:ok, state}
      end
    end
  end
end
