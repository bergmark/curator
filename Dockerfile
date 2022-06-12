FROM docker.pkg.github.com/bergmark/curator/base-build:1b786d349d098c0f393d84b28c5f8204c9fd7861 as build-app

RUN mkdir -p /artifacts/bin
COPY . /src
RUN stack install --stack-yaml /src/stack.yaml --local-bin-path /artifacts/bin

FROM docker.pkg.github.com/bergmark/curator/base-run:1b786d349d098c0f393d84b28c5f8204c9fd7861

RUN mkdir -p /app/db
COPY --from=build-app /artifacts/bin/casa-curator /usr/local/bin/casa-curator
COPY --from=build-app /artifacts/bin/curator /usr/local/bin/curator
