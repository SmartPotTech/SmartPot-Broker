FROM eclipse-mosquitto:latest

LABEL maintainer="smartpottech@gmail.com" \
      version="1.0.0" \
      description="Doker image for SmartPot Broker " \
      license="MIT" \
      created="2026-04-12" \
      repository="https://github.com/SmartPotTech/SmartPot-Broker" \
      environment="local"

COPY mosquitto.conf /mosquitto/config/mosquitto.conf
