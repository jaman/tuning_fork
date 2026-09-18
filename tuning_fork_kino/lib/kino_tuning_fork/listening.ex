defmodule KinoTuningFork.Listening do
  @moduledoc """
  Whether the page of a cell is listening, so the cell streams its stage's PCM to the
  browser only while it is. The player in the page reports it: `"listening"` with
  `%{"on" => true}` when it starts and `false` when it stops.

      def handle_event("listening", %{"on" => on}, ctx), do: {:noreply, Listening.set(ctx, on)}
      def handle_info({:pcm, chunk}, ctx), do: {:noreply, Listening.forward(ctx, chunk)}
  """

  import Kino.JS.Live.Context, only: [assign: 2, broadcast_event: 3]

  @doc "The context with the page not listening, as a cell starts and as a page connects."
  @spec init(Kino.JS.Live.Context.t()) :: Kino.JS.Live.Context.t()
  def init(ctx), do: assign(ctx, listening: false)

  @doc "Record what the page said."
  @spec set(Kino.JS.Live.Context.t(), term()) :: Kino.JS.Live.Context.t()
  def set(ctx, on), do: assign(ctx, listening: on == true)

  @doc "Whether the page is listening."
  @spec listening?(Kino.JS.Live.Context.t()) :: boolean()
  def listening?(ctx), do: ctx.assigns[:listening] == true

  @doc "Send `chunk` to the page as a `\"pcm\"` event while it is listening; drop it otherwise."
  @spec forward(Kino.JS.Live.Context.t(), binary()) :: Kino.JS.Live.Context.t()
  def forward(ctx, chunk) do
    if listening?(ctx), do: broadcast_event(ctx, "pcm", {:binary, %{}, chunk})
    ctx
  end
end
