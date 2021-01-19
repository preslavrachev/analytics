defmodule PlausibleWeb.StatsController do
  use PlausibleWeb, :controller
  use Plausible.Repo
  alias Plausible.Stats.Clickhouse, as: Stats
  alias Plausible.Stats.Query

  plug PlausibleWeb.AuthorizeStatsPlug when action in [:stats, :csv_export]
  plug PlausibleWeb.UpgradeBillingPlug when action in [:stats]

  def base_domain() do
    PlausibleWeb.Endpoint.host()
  end

  def stats(%{assigns: %{site: site}} = conn, _params) do
    if Stats.has_pageviews?(site) do
      demo = site.domain == base_domain()
      offer_email_report = get_session(conn, site.domain <> "_offer_email_report")

      conn
      |> assign(:skip_plausible_tracking, !demo)
      |> remove_email_report_banner(site)
      |> put_resp_header("x-robots-tag", "noindex")
      |> render("stats.html",
        site: site,
        has_goals: Plausible.Sites.has_goals?(site),
        title: "Plausible · " <> site.domain,
        offer_email_report: offer_email_report,
        demo: demo
      )
    else
      conn
      |> assign(:skip_plausible_tracking, true)
      |> render("waiting_first_pageview.html", site: site)
    end
  end

  def csv_export(conn, %{"domain" => domain}) do
    site = conn.assigns[:site]

    query = Query.from(site.timezone, conn.params)
    {plot, labels, _} = Stats.calculate_plot(site, query)

    csv_content =
      Enum.zip(labels, plot)
      |> Enum.map(fn {k, v} -> [k, v] end)
      |> (fn data -> [["Date", "Visitors"] | data] end).()
      |> CSV.encode()
      |> Enum.into([])
      |> Enum.join()

    filename =
      "Visitors #{domain} #{Timex.format!(query.date_range.first, "{ISOdate} ")} to #{
        Timex.format!(query.date_range.last, "{ISOdate} ")
      }.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, csv_content)
  end

  def shared_link(conn, %{"slug" => slug}) do
    shared_link =
      Repo.get_by(Plausible.Site.SharedLink, slug: slug)
      |> Repo.preload(:site)

    if shared_link do
      if shared_link.password_hash do
        conn
        |> assign(:skip_plausible_tracking, true)
        |> render("shared_link_password.html",
          link: shared_link,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      else
        shared_link_auth_success(conn, shared_link)
      end
    else
      render_error(conn, 404)
    end
  end

  def authenticate_shared_link(conn, %{"slug" => slug, "password" => password}) do
    shared_link =
      Repo.get_by(Plausible.Site.SharedLink, slug: slug)
      |> Repo.preload(:site)

    if shared_link do
      if Plausible.Auth.Password.match?(password, shared_link.password_hash) do
        shared_link_auth_success(conn, shared_link)
      else
        conn
        |> assign(:skip_plausible_tracking, true)
        |> render("shared_link_password.html",
          link: shared_link,
          error: "Incorrect password. Please try again.",
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      end
    else
      render_error(conn, 404)
    end
  end

  defp shared_link_auth_success(conn, shared_link) do
    shared_link_key = "shared_link_auth_" <> shared_link.site.domain

    conn
    |> put_session(shared_link_key, %{
      valid_until: Timex.now() |> Timex.shift(hours: 1) |> DateTime.to_unix()
    })
    |> redirect(to: "/#{URI.encode_www_form(shared_link.site.domain)}")
  end

  defp remove_email_report_banner(conn, site) do
    if conn.assigns[:current_user] do
      delete_session(conn, site.domain <> "_offer_email_report")
    else
      conn
    end
  end
end
