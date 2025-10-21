#!/usr/bin/env bash
set -euo pipefail

mkdir -p consumer
cat > consumer/pom.xml <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>test.local</groupId>
  <artifactId>consumer</artifactId>
  <version>0.0.1</version>
  <repositories>
    <repository>
      <id>local-repo</id>
      <url>file://${project.basedir}/../local-mvn-repo</url>
    </repository>
  </repositories>
  <dependencies/>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-dependency-plugin</artifactId>
        <version>3.6.1</version>
        <executions>
          <execution>
            <id>copy-ontology-jars</id>
            <phase>process-resources</phase>
            <goals><goal>copy</goal></goals>
            <configuration>
              <artifactItems/>
              <overWrite>true</overWrite>
              <transitive>false</transitive>
              <outputAbsoluteArtifactFilename>false</outputAbsoluteArtifactFilename>
            </configuration>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>
</project>
POM

# Expect input lines like: group:id:version
while IFS=: read -r G A V; do
  echo "$G"
  [ -z "${G:-}" ] && continue
  xmlstarlet ed -L \
    -N p="http://maven.apache.org/POM/4.0.0" \
    -s "/p:project/p:dependencies" -t elem -n "dependency" -v "" \
    -s "/p:project/p:dependencies/*[local-name()='dependency'][last()]" -t elem -n "groupId" -v "$G" \
    -s "/p:project/p:dependencies/*[local-name()='dependency'][last()]" -t elem -n "artifactId" -v "$A" \
    -s "/p:project/p:dependencies/*[local-name()='dependency'][last()]" -t elem -n "version" -v "$V" \
    -s "/p:project/p:dependencies/*[local-name()='dependency'][last()]" -t elem -n "type" -v "jar" \
    consumer/pom.xml

xmlstarlet ed -L \
  -N p="http://maven.apache.org/POM/4.0.0" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems" \
      -t elem -n "artifactItem" -v "" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems/*[local-name()='artifactItem'][last()]" \
      -t elem -n "groupId" -v "$G" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems/*[local-name()='artifactItem'][last()]" \
      -t elem -n "artifactId" -v "$A" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems/*[local-name()='artifactItem'][last()]" \
      -t elem -n "version" -v "$V" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems/*[local-name()='artifactItem'][last()]" \
      -t elem -n "type" -v "jar" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems/*[local-name()='artifactItem'][last()]" \
      -t elem -n "outputDirectory" -v "\${project.build.directory}/deps" \
  -s "/p:project/p:build/p:plugins/p:plugin[
        p:groupId='org.apache.maven.plugins' and
        p:artifactId='maven-dependency-plugin'
      ]/p:executions/p:execution/p:configuration/p:artifactItems/*[local-name()='artifactItem'][last()]" \
      -t elem -n "destFileName" -v "${A}-${V}.jar" \
  consumer/pom.xml


done < "${1:-/dev/stdin}"
