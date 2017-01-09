var articles2 = db.articles2.find();

articles2.forEach(function(articles2){
	db.articles.insert({title:articles2.title,path:articles2.path,date:articles2.date,images:articles2.images,body:articles2.body});
});
