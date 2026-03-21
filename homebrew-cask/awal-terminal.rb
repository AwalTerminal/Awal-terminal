cask "awal-terminal" do
  version "0.18.0"
  sha256 "151c13978f050ccf78d7c0d66c42dd52466214ab1cf1a7fa05faee6208152bb6"

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
