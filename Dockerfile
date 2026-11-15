# Publishes api with the .NET SDK and runs it on the chiseled ASP.NET runtime as a non-root user, on port 8080.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY global.json Directory.Build.props .editorconfig ./
COPY src/ src/
RUN dotnet publish src/KubernetesLearning.Api --configuration Release --output /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "KubernetesLearning.Api.dll"]
