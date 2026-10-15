require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "should get index" do
    get articles_url
    assert_response :success
  end

  test "should get new" do
    get new_article_url
    assert_response :success
  end

  test "should create article" do
    assert_difference("Article.count") do
      post articles_url, params: { article: { ARTNAME_UNICODE: @article.ARTNAME_UNICODE, ARTNO: @article.ARTNO, ASSQ: @article.ASSQ, CP_Height: @article.CP_Height, CP_Length: @article.CP_Length, CP_Sale_Sol_Name: @article.CP_Sale_Sol_Name, CP_Weight_Gross: @article.CP_Weight_Gross, CP_Width: @article.CP_Width, DIV: @article.DIV, DT: @article.DT, DTFP: @article.DTFP, DTFP_PLUS: @article.DTFP_PLUS, End_Date_Sale: @article.End_Date_Sale, Item_No: @article.Item_No, MAX: @article.MAX, MIN: @article.MIN, MPQ: @article.MPQ, PALQ: @article.PALQ, RSSQ: @article.RSSQ, SLID: @article.SLID, SRP: @article.SRP, SSQ: @article.SSQ, Start_Date_Sale: @article.Start_Date_Sale, UL_Height_Gross: @article.UL_Height_Gross, UL_Length_Gross: @article.UL_Length_Gross, UL_Sale_Sol_Name: @article.UL_Sale_Sol_Name, UL_Width_Gross: @article.UL_Width_Gross, new_slid: @article.new_slid, planned: @article.planned, store_id: @article.store_id } }
    end

    assert_redirected_to article_url(Article.last)
  end

  test "should show article" do
    get article_url(@article)
    assert_response :success
  end

  test "should get edit" do
    get edit_article_url(@article)
    assert_response :success
  end

  test "should update article" do
    patch article_url(@article), params: { article: { ARTNAME_UNICODE: @article.ARTNAME_UNICODE, ARTNO: @article.ARTNO, ASSQ: @article.ASSQ, CP_Height: @article.CP_Height, CP_Length: @article.CP_Length, CP_Sale_Sol_Name: @article.CP_Sale_Sol_Name, CP_Weight_Gross: @article.CP_Weight_Gross, CP_Width: @article.CP_Width, DIV: @article.DIV, DT: @article.DT, DTFP: @article.DTFP, DTFP_PLUS: @article.DTFP_PLUS, End_Date_Sale: @article.End_Date_Sale, Item_No: @article.Item_No, MAX: @article.MAX, MIN: @article.MIN, MPQ: @article.MPQ, PALQ: @article.PALQ, RSSQ: @article.RSSQ, SLID: @article.SLID, SRP: @article.SRP, SSQ: @article.SSQ, Start_Date_Sale: @article.Start_Date_Sale, UL_Height_Gross: @article.UL_Height_Gross, UL_Length_Gross: @article.UL_Length_Gross, UL_Sale_Sol_Name: @article.UL_Sale_Sol_Name, UL_Width_Gross: @article.UL_Width_Gross, new_slid: @article.new_slid, planned: @article.planned, store_id: @article.store_id } }
    assert_redirected_to article_url(@article)
  end

  test "should destroy article" do
    assert_difference("Article.count", -1) do
      delete article_url(@article)
    end

    assert_redirected_to articles_url
  end
end
