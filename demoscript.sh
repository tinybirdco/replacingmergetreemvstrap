tb push

tb datasource append yt_views first_views.csv

tb sql "SELECT * FROM yt_views FINAL"

echo "\ntotal from RMT"

tb sql "SELECT channel, sum(views) AS total_views FROM yt_views FINAL GROUP BY channel ORDER BY channel"

echo "\ntotal from AggMT MV"

tb sql "SELECT channel, sumMerge(total_views) AS views FROM channel_views_mv GROUP BY channel ORDER BY channel"

tb datasource append yt_views second_views.csv

tb sql "SELECT * FROM yt_views FINAL"

echo "\ntotal from RMT"

tb sql "SELECT channel, sum(views) AS total_views FROM yt_views FINAL GROUP BY channel ORDER BY channel"

echo "\ntotal from AggMT MV"

tb sql "SELECT channel, sumMerge(total_views) AS views FROM channel_views_mv GROUP BY channel ORDER BY channel"

echo "check if total for tinybirdco is as expected"