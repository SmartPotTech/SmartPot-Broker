FROM eclipse-mosquitto:2.1.2-alpine

LABEL org.opencontainers.image.title="SmartPot Broker" \
      org.opencontainers.image.description="Broker MQTT de SmartPot con seguridad dinámica por dispositivo" \
      org.opencontainers.image.source="https://github.com/SmartPotTech/SmartPot-Broker" \
      org.opencontainers.image.licenses="MIT"

COPY --chown=1883:1883 config/mosquitto.conf /mosquitto/config/mosquitto.conf
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/smartpot-entrypoint.sh

USER 1883:1883

VOLUME ["/mosquitto/data"]

EXPOSE 1883 8883 9001

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD nc -z 127.0.0.1 1883 || exit 1

ENTRYPOINT ["/usr/local/bin/smartpot-entrypoint.sh"]

CMD ["mosquitto"]
