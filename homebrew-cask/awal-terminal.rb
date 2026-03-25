cask "awal-terminal" do
  version "0.22.1"
  sha256 "94fe6e6bcd6858f13227db99283598925a3e3f8f8c522de5e6ca09163ab5d2fe"

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
