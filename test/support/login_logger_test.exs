defmodule ExMoney.Saltedge.Test.LoginLogger do
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: :login_logger_test)
  end

  def log_event(callback, event, login_id, params) do
    GenServer.cast(:login_logger_test, {:log, callback, event, login_id, params})
  end

  def handle_cast({:log, _callback, _event, _saltedge_login_id, _params}, state) do
    {:noreply, state}
  end
end
