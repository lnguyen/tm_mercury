defmodule TM.Mercury.Mixfile do
  use Mix.Project

  def project do
    [app: :tm_mercury,
     version: "0.2.1",
     elixir: "~> 1.4.0",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     description: description(),
     package: package(),
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [extra_applications: [:logger, :connection, :nerves_uart]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:connection, "~> 1.0.0"},
     {:nerves_uart, "~> 0.1"},
     {:ex_doc, "~> 0.14", only: :dev, runtime: false}]
  end

  defp description do
    """
    A pure Elixir implementation of the ThingMagic Mercury SDK
    """
  end

  defp package do
    [maintainers: ["Justin Schneck", "Jeff Smith"],
     licenses: ["Apache 2.0"],
     links: %{"Github" => "https://github.com/letoteteam/tm_mercury"}]
  end
end
