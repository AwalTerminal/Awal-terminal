cask "awal-terminal" do
  version "0.10.0"
  sha256 "24f84412a4fb4df682167e92f3bdd7d87e89de9c3b8d53c97a73057ad612aaad"

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
