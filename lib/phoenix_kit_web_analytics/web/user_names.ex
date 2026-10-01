defmodule PhoenixKitWebAnalytics.Web.UserNames do
  @moduledoc false
  # Display names for the signed-in users that appear in sessions and the live
  # list — through core's `User.display_name/1`, so a page shows the same name
  # everywhere in the admin and never an email address.

  import Ecto.Query

  require Logger

  alias PhoenixKit.Users.Auth.User

  @doc "A map of `uuid => display name` for the given UUIDs (nils ignored)."
  @spec for_uuids([String.t() | nil]) :: %{String.t() => String.t()}
  def for_uuids(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      list ->
        from(u in User, where: u.uuid in ^list)
        |> PhoenixKit.RepoHelper.repo().all()
        |> Map.new(&{&1.uuid, User.display_name(&1)})
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error, Ecto.Query.CastError] ->
      Logger.debug("[WebAnalytics] user names unavailable: #{Exception.message(error)}")
      %{}
  end
end
