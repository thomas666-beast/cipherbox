import axios from 'axios'

const api = axios.create({
  baseURL: '/api',
  withCredentials: true,
})

api.interceptors.response.use(
  (res) => res,
  (err) => {
    if (err.response && err.response.status === 401) {
      if (location.pathname !== '/login' && location.pathname !== '/register') {
        location.href = '/login'
      }
    }
    return Promise.reject(err)
  }
)

export default api
