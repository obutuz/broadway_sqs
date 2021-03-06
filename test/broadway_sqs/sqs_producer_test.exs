defmodule BroadwaySQS.SQSProducerTest do
  use ExUnit.Case

  alias BroadwaySQS.SQSProducer
  alias Broadway.Message

  defmodule MessageServer do
    def start_link() do
      Agent.start_link(fn -> [] end)
    end

    def push_messages(server, messages) do
      Agent.update(server, fn queue -> queue ++ messages end)
    end

    def take_messages(server, amount) do
      Agent.get_and_update(server, &Enum.split(&1, amount))
    end
  end

  defmodule FakeSQSClient do
    @behaviour BroadwaySQS.SQSClient

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def receive_messages(amount, opts, ack_module) do
      messages = MessageServer.take_messages(opts.message_server, amount)
      send(opts.test_pid, {:messages_received, length(messages)})

      for msg <- messages do
        ack_data = %{
          receipt: %{id: "Id_#{msg}", receipt_handle: "ReceiptHandle_#{msg}"},
          sqs_client: {__MODULE__, opts}
        }

        %Message{data: msg, acknowledger: {ack_module, ack_data}}
      end
    end

    @impl true
    def delete_messages(receipts, opts) do
      send(opts.test_pid, {:messages_deleted, length(receipts)})
    end
  end

  defmodule Forwarder do
    use Broadway

    def handle_message(message, %{test_pid: test_pid}) do
      send(test_pid, {:message_handled, message.data})
      {:ok, message}
    end

    def handle_batch(_, messages, _, _) do
      {:ack, successful: messages, failed: []}
    end
  end

  test "raise an ArgumentError with proper message when client options are invalid" do
    assert_raise(
      ArgumentError,
      "invalid options given to BroadwaySQS.ExAwsClient.init/1, expected :queue_name to be a non empty string, got: nil",
      fn ->
        SQSProducer.init(queue_name: nil)
      end
    )
  end

  test "receive messages when the queue has less than the demand" do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    MessageServer.push_messages(message_server, 1..5)

    assert_receive {:messages_received, 5}

    for msg <- 1..5 do
      assert_receive {:message_handled, ^msg}
    end

    stop_broadway(pid)
  end

  test "keep receiving messages when the queue has more than the demand" do
    {:ok, message_server} = MessageServer.start_link()
    MessageServer.push_messages(message_server, 1..20)
    {:ok, pid} = start_broadway(message_server)

    assert_receive {:messages_received, 10}

    for msg <- 1..10 do
      assert_receive {:message_handled, ^msg}
    end

    assert_receive {:messages_received, 5}

    for msg <- 11..15 do
      assert_receive {:message_handled, ^msg}
    end

    assert_receive {:messages_received, 5}

    for msg <- 16..20 do
      assert_receive {:message_handled, ^msg}
    end

    assert_receive {:messages_received, 0}

    stop_broadway(pid)
  end

  test "keep trying to receive new messages when the queue is empty" do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    MessageServer.push_messages(message_server, [13])
    assert_receive {:messages_received, 1}
    assert_receive {:message_handled, 13}

    assert_receive {:messages_received, 0}
    refute_receive {:message_handled, _}

    MessageServer.push_messages(message_server, [14, 15])
    assert_receive {:messages_received, 2}
    assert_receive {:message_handled, 14}
    assert_receive {:message_handled, 15}

    stop_broadway(pid)
  end

  test "delete acknowledged messages" do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    MessageServer.push_messages(message_server, 1..20)

    assert_receive {:messages_deleted, 10}
    assert_receive {:messages_deleted, 10}

    stop_broadway(pid)
  end

  defp start_broadway(message_server) do
    Broadway.start_link(Forwarder, %{test_pid: self()},
      name: new_unique_name(),
      producers: [
        default: [
          module: SQSProducer,
          arg: [
            receive_interval: 0,
            sqs_client:
              {FakeSQSClient,
               %{
                 test_pid: self(),
                 message_server: message_server
               }}
          ],
          stages: 1
        ]
      ],
      processors: [stages: 1],
      publishers: [
        default: [
          batch_size: 10,
          batch_timeout: 50,
          stages: 1
        ]
      ]
    )
  end

  defp new_unique_name() do
    :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  end

  defp stop_broadway(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end
end
