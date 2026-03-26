cask "awal-terminal" do
  version "0.24.0"
  sha256 "b7f4818f667b6eec76c09b62d8a5407e6bac620296a53112f5932be79421ef9a"

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
