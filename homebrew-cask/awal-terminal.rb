cask "awal-terminal" do
  version "0.25.0"
  sha256 "2997375d9d0b1eccee485390c624d78109acb4d08e9c65e4cae4b1c6fcfb3159"

  url "https://github.com/AwalTerminal/awal-terminal/releases/download/v#{version}/AwalTerminal.zip"
  name "Awal Terminal"
  desc "LLM-native terminal emulator for macOS"
  homepage "https://awalterminal.github.io/awal-terminal/"

  depends_on macos: ">= :sonoma"

  app "AwalTerminal.app"

  zap trash: [
    "~/.config/awal",
  ]
end
