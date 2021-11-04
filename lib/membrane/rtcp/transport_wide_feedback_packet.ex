defmodule Membrane.RTCP.TransportWideFeedbackPacket do
  @moduledoc """
  Abstraction and generic encoding and decoding functionality for
  [RTCP transport-wide feedback packets](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01).
  """

  @behaviour Membrane.RTCP.Packet

  alias Membrane.RTP

  @enforce_keys [:origin_ssrc, :media_ssrc, :payload]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          origin_ssrc: RTP.ssrc_t(),
          media_ssrc: RTP.ssrc_t(),
          payload: struct
        }

  @callback decode(binary()) :: {:ok, struct()} | {:error, any()}

  @callback encode(struct()) :: binary()

  @packet_type_payload BiMap.new(%{
                         15 => __MODULE__.TWCC
                       })

  @impl true
  def decode(<<origin_ssrc::32, media_ssrc::32, payload::binary>>, packet_type) do
    with {:ok, module} <- BiMap.fetch(@packet_type_payload, packet_type),
         {:ok, payload} <- module.decode(payload) do
      {:ok, %__MODULE__{origin_ssrc: origin_ssrc, media_ssrc: media_ssrc, payload: payload}}
    else
      :error -> {:error, {:unknown_feedback_packet_type, packet_type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def decode(_binary, _packet_type) do
    {:error, :malformed_packet}
  end

  @impl true
  @spec encode(Membrane.RTCP.TransportWideFeedbackPacket.t()) :: {<<_::64, _::_*8>>, any}
  def encode(%__MODULE__{} = packet) do
    %module{} = packet.payload
    packet_type = BiMap.fetch_key!(@packet_type_payload, module)

    {<<packet.origin_ssrc::32, packet.media_ssrc::32, module.encode(packet.payload)::binary>>,
     packet_type}
  end
end
