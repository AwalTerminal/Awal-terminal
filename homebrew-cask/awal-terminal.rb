cask "awal-terminal" do
  version "0.19.0"
  sha256 "51cf66c1fdb20d5c0aa1b448c772b63d81a1d5cc1464a651c68cb7535499c9ed"

  url "https://github.com/AwalTerminal/Awal-terminal/releases/download/v#{version}/AwalTerminal.zip"
  name "Awal Terminal"
  desc "LLM-native terminal emulator for macOS"
  homepage "https://awalterminal.github.io/Awal-terminal/"

  depends_on macos: ">= :sonoma"

  app "AwalTerminal.app"

  zap trash: [
    "~/.config/awal",
  ]
end
