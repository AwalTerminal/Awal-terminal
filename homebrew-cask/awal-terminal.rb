cask "awal-terminal" do
  version "0.25.2"
  sha256 "b05936b1e1ed1b73dece396f5445f46aa692c51f1aa28638a6d13a025bf92fb2"

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
