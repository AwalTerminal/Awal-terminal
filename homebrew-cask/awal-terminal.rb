cask "awal-terminal" do
  version "0.17.0"
  sha256 "2fc21b139b2518b6e9ab8befc9bfab63205ec6d1776e19668d69c631ca949ef7"

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
