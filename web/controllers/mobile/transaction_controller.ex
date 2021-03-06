defmodule ExMoney.Mobile.TransactionController do
  use ExMoney.Web, :controller
  alias ExMoney.{Repo, Transaction, Category, Account, TransactionInfo, FavouriteTransaction}

  plug Guardian.Plug.EnsureAuthenticated, handler: ExMoney.Guardian.Mobile.Unauthenticated
  plug :put_layout, "mobile.html"

  def index(conn, %{"date" => date, "account_id" => account_id, "category_id" => category_id}) do
    account = Repo.get!(Account, account_id)
    category = Repo.get!(Category, category_id)
    category_ids = case category.parent_id do
      nil -> [category.id | Repo.all(Category.sub_categories_by_id(category.id))]
      _parent_id -> [category.id]
    end
    parsed_date = parse_date(date)
    from = first_day_of_month(parsed_date)
    to = last_day_of_month(parsed_date)

    transactions = Transaction.by_month_by_category(account_id, from, to, category_ids)
    |> Repo.all
    |> Enum.group_by(fn(transaction) ->
      transaction.made_on
    end)
    |> Enum.sort(fn({date_1, _transactions}, {date_2, _transaction}) ->
      Ecto.Date.compare(date_1, date_2) != :lt
    end)

    {:ok, formatted_date} = Timex.DateFormat.format(parsed_date, "%b %Y", :strftime)

    from = case transactions do
      [] -> "/m/accounts/#{account_id}"
      _ -> "/m/transactions?date=#{date}&category_id=#{category_id}&account_id=#{account_id}"
    end |> URI.encode_www_form

    render conn, :index,
      currency_label: account.currency_label,
      transactions: transactions,
      date: %{label: formatted_date, value: date},
      category: category.humanized_name,
      from: from,
      account_id: account.id
  end

  def new(conn, _params) do
    categories = categories_list
    uncategorized = Map.keys(categories)
    |> Enum.find(fn({name, _id}) -> name == "Uncategorized" end)
    categories = Map.delete(categories, uncategorized)
    categories = [{uncategorized, []} | Map.to_list(categories)]

    accounts = Account.only_custom |> Repo.all

    changeset = Transaction.changeset_custom(%Transaction{})

    render conn, :new,
      categories: categories,
      changeset: changeset,
      accounts: accounts
  end

  def edit(conn, %{"id" => id, "from" => from}) do
    transaction = Repo.get(Transaction, id)
    categories = categories_list
    changeset = Transaction.update_changeset(transaction)

    render conn, :edit,
      transaction: transaction,
      categories: categories,
      changeset: changeset,
      from: from
  end

  def update(conn, %{"id" => id, "transaction" => transaction_params}) do
    transaction = Repo.get!(Transaction, id)

    from = validate_from_param(transaction_params["from"])

    changeset = Transaction.update_changeset(transaction, transaction_params)

    case Repo.update(changeset) do
      {:ok, _transaction} ->
        send_resp(conn, 200, from)
      {:error, _changeset} ->
        send_resp(conn, 422, "Something went wrong, check server logs")
    end
  end

  def create(conn, %{"transaction" => transaction_params}) do
    user = Guardian.Plug.current_resource(conn)
    transaction_params = Map.put(transaction_params, "user_id", user.id)
    changeset = Transaction.changeset_custom(%Transaction{}, transaction_params)

    Repo.transaction fn ->
      transaction = Repo.insert!(changeset)
      account = Repo.get!(Account, transaction.account_id)
      new_balance = Decimal.add(account.balance, transaction.amount)
      Account.update_custom_changeset(account, %{balance: new_balance})
      |> Repo.update!
    end

    send_resp(conn, 200, "")
  end

  def create_from_fav(conn, params) do
    amount =  params["transaction[amount]"]
    fav_tr_id = params["transaction[fav_tr_id]"]
    fav_tr = Repo.get!(FavouriteTransaction, fav_tr_id)

    transaction_params = %{
      "amount" => amount,
      "user_id" => fav_tr.user_id,
      "category_id" => fav_tr.category_id,
      "account_id" => fav_tr.account_id,
      "made_on" => Ecto.Date.from_erl(today()),
      "type" => "expense"
    }
    changeset = Transaction.changeset_custom(%Transaction{}, transaction_params)

    Repo.transaction fn ->
      transaction = Repo.insert!(changeset)
      account = Repo.get!(Account, transaction.account_id)
      new_balance = Decimal.add(account.balance, transaction.amount)
      Account.update_custom_changeset(account, %{balance: new_balance})
      |> Repo.update!
    end

    send_resp(conn, 200, "")
  end

  def show(conn, %{"id" => id}) do
    transaction = Repo.one(
      from tr in Transaction,
        where: tr.id == ^id,
        preload: [:account, :transaction_info, :category]
      )

    render conn, :show, transaction: transaction
  end

  def delete(conn, %{"id" => id}) do
    transaction = Repo.get!(Transaction, id)
    account = Repo.get!(Account, transaction.account_id)

    case transaction.saltedge_transaction_id do
      nil ->
        new_balance = Decimal.sub(account.balance, transaction.amount)

        Repo.transaction(fn ->
          tr_info = TransactionInfo.by_transaction_id(id) |> Repo.one
          if tr_info, do: Repo.delete!(tr_info)

          Repo.delete!(transaction)

          Account.update_custom_changeset(account, %{balance: new_balance})
          |> Repo.update!
        end)

        render conn, :delete,
          account_id: account.id,
          new_balance: new_balance
      _ ->
        Repo.transaction(fn ->
          tr_info = TransactionInfo.by_transaction_id(id) |> Repo.one
          if tr_info, do: Repo.delete!(tr_info)

          Repo.delete!(transaction)
        end)

        body = """
          { "data": [{ "transaction_id": #{transaction.saltedge_transaction_id} }]}
        """

        {:ok, _} = ExMoney.Saltedge.Client.request(:put, "transactions/duplicate", body)

        render conn, :delete, new_balance: false
    end
  end

  defp parse_date(month) do
    {:ok, date} = Timex.DateFormat.parse(month, "{YYYY}-{0M}")
    date
  end

  defp first_day_of_month(date) do
    Timex.Date.from({{date.year, date.month, 0}, {0, 0, 0}})
    |> Timex.DateFormat.format("%Y-%m-%d", :strftime)
    |> elem(1)
  end

  defp last_day_of_month(date) do
    days_in_month = Timex.Date.days_in_month(date)

    Timex.Date.from({{date.year, date.month, days_in_month}, {23, 59, 59}})
    |> Timex.DateFormat.format("%Y-%m-%d", :strftime)
    |> elem(1)
  end

  defp categories_list do
    categories_dict = Repo.all(Category)

    Enum.reduce(categories_dict, %{}, fn(category, acc) ->
      if is_nil(category.parent_id) do
        sub_categories = Enum.filter(categories_dict, fn(c) -> c.parent_id == category.id end)
        |> Enum.map(fn(sub_category) -> {sub_category.humanized_name, sub_category.id} end)
        Map.put(acc, {category.humanized_name, category.id}, sub_categories)
      else
        acc
      end
    end)
  end

  # FIXME: that looks terrible, I'm really sorry.
  defp validate_from_param(from) do
    if String.match?(from, ~r/\A\/m\/accounts\/\d+\/(expenses|income)\?date=\d{4}-\d{1,2}\z/) or
      String.match?(from, ~r/\A\/m\/transactions\?date=\d{4}-\d{1,2}\&category_id=\d+\&account_id=\d+\z/) or
      String.match?(from, ~r/\A\/m\/accounts\/\d+\z/) do

      from
    else
      "/m/dashboard"
    end
  end

  defp today() do
    {today, _} = :calendar.local_time()
    today
  end
end
