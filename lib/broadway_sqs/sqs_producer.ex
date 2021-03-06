defmodule BroadwaySQS.SQSProducer do
  @moduledoc """
  A GenStage producer that continuously receives messages from a SQS queue and
  acknowledge them after being successfully processed.

  ## Options

    * `:sqs_client` - Optional. A tuple defining the client (and its options) responsible
      for fetching and acknowledging the messages. Default is `{ExAwsClient, []}`.
    * `:receive_interval` - Optional. The duration (in milliseconds) for which the producer
      waits before making a request for more messages. Default is 5000.

  ### Example

      Broadway.start_link(MyBroadway, %{},
        name: MyBroadway,
        producers: [
          default: [
            module: BroadwaySQS.SQSProducer,
            arg: [
              sqs_client: {BroadwaySQS.ExAwsClient, [
                queue_name: "my_queue",
              ]}
            ],
          ],
        ],
      )

  The above configuration will set up a producer that continuously receives messages from `"my_queue"`
  and sends them downstream. In case you want to tune you configuration, see all options
  provided by `BroadwaySQS.ExAwsClient`.

  """

  use GenStage

  alias Broadway.{Message, Acknowledger}

  @behaviour Acknowledger

  @max_num_messages_allowed_by_aws 10
  @default_receive_interval 5000

  @impl true
  def init(opts) do
    {client, client_opts} = opts[:sqs_client] || {BroadwaySQS.ExAwsClient, []}
    receive_interval = opts[:receive_interval] || @default_receive_interval

    case client.init(client_opts) do
      {:error, message} ->
        raise ArgumentError, "invalid options given to #{inspect(client)}.init/1, " <> message

      {:ok, opts} ->
        {:producer,
         %{
           demand: 0,
           receive_timer: nil,
           receive_interval: receive_interval,
           sqs_client: {client, opts}
         }}
    end
  end

  @impl true
  def handle_demand(incoming_demand, %{demand: demand} = state) do
    handle_receive_messages(%{state | demand: demand + incoming_demand})
  end

  @impl true
  def handle_info(:receive_messages, state) do
    handle_receive_messages(%{state | receive_timer: nil})
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, [], state}
  end

  @impl Acknowledger
  def ack(successful, _failed) do
    successful
    |> Enum.chunk_every(@max_num_messages_allowed_by_aws)
    |> Enum.each(&delete_messages_from_sqs/1)
  end

  def handle_receive_messages(%{receive_timer: nil, demand: demand} = state) when demand > 0 do
    messages = receive_messages_from_sqs(state, demand)
    new_demand = demand - length(messages)

    receive_timer =
      case {messages, new_demand} do
        {[], _} -> schedule_receive_messages(state.receive_interval)
        {_, 0} -> nil
        _ -> schedule_receive_messages(0)
      end

    {:noreply, messages, %{state | demand: new_demand, receive_timer: receive_timer}}
  end

  def handle_receive_messages(state) do
    {:noreply, [], state}
  end

  defp receive_messages_from_sqs(state, total_demand) do
    %{sqs_client: {client, opts}} = state
    client.receive_messages(total_demand, opts, __MODULE__)
  end

  defp delete_messages_from_sqs(messages) do
    [%Message{acknowledger: {_, %{sqs_client: {client, opts}}}} | _] = messages
    receipts = Enum.map(messages, &extract_message_receipt/1)
    client.delete_messages(receipts, opts)
  end

  defp extract_message_receipt(message) do
    {_, %{receipt: receipt}} = message.acknowledger
    receipt
  end

  defp schedule_receive_messages(interval) do
    Process.send_after(self(), :receive_messages, interval)
  end
end
